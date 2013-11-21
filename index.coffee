phantom = require("phantom")
cluster = require("cluster")
events = require("events")
zmq = require("zmq")

# Default number of iterations to execute per worker before killing the worker
# process. This is done to prevent memory leaks from phantomjs.
DEFAULT_WORKER_ITERATIONS = 100

# How often to check for when the cluster should be shutdown. This happens
# when the work queue is empty and there are no pending tasks left.
STOP_QUEUE_CHECKING_INTERVAL = 10

# Default time to wait (in ms) before considering a job dead and re-spawning
# it for another worker to execute.
DEFAULT_MESSAGE_TIMEOUT = 60 * 1000

# Default connection string for master/worker sockets on ZeroMQ.
DEFAULT_ZMQ_CONNECTION_STRING = "ipc:///tmp/phantom-cluster"

# Checks whether an object is empty
empty = (obj) ->
    for key of obj
        return false
    return true

# Creates a new cluster
create = (options) ->
    if cluster.isMaster
        new PhantomClusterServer(options)
    else
        new PhantomClusterClient(options)

# Creates a cluster with a work queue
createQueued = (options) ->
    if cluster.isMaster
        new PhantomQueuedClusterServer(options)
    else
        new PhantomQueuedClusterClient(options)

# A basic cluster server/master. Communication is not handled in this,
# although it can be extended to use whatever communication primitives, as is
# done with PhantomQueuedClusterServer.
class PhantomClusterServer extends events.EventEmitter
    constructor: (options) ->
        super

        # Number of workers to spawn
        @numWorkers = options.workers or require("os").cpus().length

        # Object of worker IDs -> worker objects
        @workers = {}

        # Whether we're done
        @done = false

    # Adds a new worker to the cluster
    addWorker: () ->
        worker = cluster.fork()
        @workers[worker.id] = worker
        @emit("workerStarted", worker)

    # Starts the server
    start: () ->
        # When a worker dies, create a new one unless we're done
        cluster.on "exit", (worker, code, signal) =>
            @emit("workerDied", worker, code, signal)
            delete @workers[worker.id]
            if not @done then @addWorker()

        # Add all the workers
        for i in [0...this.numWorkers]
            @addWorker()

        @emit("started")

    # Stops the server
    stop: () ->
        if not @done
            @done = true

            # Kill the workers
            for _, worker of @workers
                worker.kill()

            @emit("stopped")

# A basic cluster client/worker. Communication is not handled in this,
# although it can be extended to use whatever communication primitives, as is
# done with PhantomQueuedClusterClient.
class PhantomClusterClient extends events.EventEmitter
    constructor: (options) ->
        super

        # Phantom instance
        @ph = null

        # Number of iterations to perform before killing this client
        @iterations = options.workerIterations or DEFAULT_WORKER_ITERATIONS

        # Arguments to pass to start the phantom instance
        @phantomArguments = options.phantomArguments or []

        # Where the phantom binary is
        @phantomBinary = options.phantomBinary or require("phantomjs").path

        # Base port to start the phantom process. The worker ID is added to
        # this to create a unique port.
        @phantomBasePort = this.phantomBasePort or 12300

        # Whether we're done
        @done = false

    start: () ->
        options = {
            binary: @phantomBinary,
            port: @phantomBasePort + cluster.worker.id + 1,
            onExit: () =>
                # When phantom dies, kill this worker
                @emit("phantomDied")
                @stop()
        }

        onStart = (ph) =>
            # Called when phantom starts up
            @ph = ph
            @emit("phantomStarted")
            @next()

        # Run phantom
        phantom.create.apply(phantom, @phantomArguments.concat([options, onStart]))
        @emit("started")

    next: () ->
        # Called when a work item is completed

        if not @done
            # Decrement the number of iterations left available to this worker
            @iterations--

            # If we're out of iterations, kill this worker
            if @iterations >= 0
                @emit("workerReady")
            else
                @stop()

    stop: () ->
        # Kill this worker on stop
        if not @done
            @done = true
            @emit("stopped")
            process.nextTick(() -> process.exit(0))

# A cluster server/master that has a queue of work items. Items are passed off to clients
# to run via a ZeroMQ socket.
class PhantomQueuedClusterServer extends PhantomClusterServer
    constructor: (options) ->
        super options

        # Connection string for the ZeroMQ socket to bind to
        @zmqConnectionString = options.zmqConnectionString or DEFAULT_ZMQ_CONNECTION_STRING

        # Timeout (in ms) before a message is considered dead
        @messageTimeout = options.messageTimeout or DEFAULT_MESSAGE_TIMEOUT

        # Object of message IDs -> messages that are pending completion
        @_sentMessages = {}

        # Counter for generating unique message IDs
        @_messageIdCounter = 0

        # Timer to check when we're out of tasks and stop the server
        @_stopCheckingInterval = null

        # Queue if pending tasks
        @queue = []

        # ZeroMQ socket to listen on for client requests
        @_socket = zmq.socket("rep")
        @_socket.bindSync(@zmqConnectionString)
        @_socket.on "message", @_onSocketMessage

        @on "started", @_onStart
        @on "stopped", @_onStop

    enqueue: (request) ->
        # Enqueues a new request to pass off to a client
        item = new QueueItem(@_messageIdCounter++, request)

        item.on "timeout", () =>
            # When an item times out, re-enqueue it
            delete @_sentMessages[item.id]
            @enqueue(request)

        @queue.push(item)
        item

    _onStart: () =>
        # Starts the timer to check for completion
        @_stopCheckingInterval = setInterval(() =>
            # When there are no tasks pending completion, and there are no
            # tasks waiting to be run by a worker, exit out
            if not @done and @queue.length == 0 and empty(@_sentMessages) then @stop()
        , STOP_QUEUE_CHECKING_INTERVAL)

    _onStop: () =>
        # Close the socket and kill the timer on stop
        if @_stopCheckingInterval != null then clearInterval(@_stopCheckingInterval)
        @_socket.close()

    _onSocketMessage: (message) =>
        # Parse the message into JSON
        json = JSON.parse(message.toString())

        if json.action == "queueItemRequest"
            # Request from the client for a new work item

            if @queue.length > 0
                # Give a new work item if the queue isn't empty
                item = @queue.shift()

                # Start the item, which will start the timeout on it
                item.start(@messageTimeout)

                # Send the item off
                @_socket.send(JSON.stringify({
                    action: "queueItemRequest",
                    id: item.id,
                    request: item.request
                }))
                
                # Add the item to the pending tasks
                @_sentMessages[item.id] = item
            else
                # Send a message signifying we're done
                @_socket.send(JSON.stringify({
                    action: "done"
                }))
        else if json.action == "queueItemResponse"
            # Request from the client stating it has completed a task

            # Look up the item
            item = @_sentMessages[json.id]

            if item
                # Finish up the item if it still exists
                item.finish(json.response)
                delete @_sentMessages[json.id]

                @_socket.send(JSON.stringify({
                    action: "OK"
                }))
            else
                # If the item doesn't exist, notify the client that the
                # completion was ignored
                @_socket.send(JSON.stringify({
                    action: "ignored"
                }))

class PhantomQueuedClusterClient extends PhantomClusterClient
    constructor: (options) ->
        super options

        # Connection string for the ZeroMQ socket to connect to
        @zmqConnectionString = options.zmqConnectionString or DEFAULT_ZMQ_CONNECTION_STRING
        
        # The ID of the message we're currently processing
        @currentRequestId = null

        # ZeroMQ socket to listen to server responses on
        @_socket = zmq.socket("req")
        @_socket.connect(@zmqConnectionString)
        @_socket.on "message", @_onSocketMessage

        @on "stopped", @_onStop
        @on "workerReady", @_onWorkerReady

    queueItemResponse: (response) ->
        # This method should be called by the function that handles a work
        # item. When the work item is completed, this function is called
        # with the response. The response will then be shipped off to the
        # server over a ZeroMQ socket.
        @_socket.send(JSON.stringify({
            action: "queueItemResponse",
            id: @currentRequestId,
            response: response
        }))

        @next()

    _onStop: () =>
        # Close the socket on stop
        @_socket.close()

    _onSocketMessage: (message) =>
        # Parse the message
        json = JSON.parse(message.toString())

        if json.action == "queueItemRequest"
            # A response from the server that has a task for this client
            # to execute
            @currentRequestId = json.id
            @emit("queueItemReady", json.request)
        else if json.action == "queueItemResponse"
            # A response from the server acknowledging it has received a task
            # response from us
            if json.status not in ["OK", "ignored"]
                throw new Error("Unexpected status code from queueItemResponse message: #{json.status}")
        else if json.action == "done"
            # A response from the server saying there are no tasks left.
            # Exit out.
            @stop()

    _onWorkerReady: () =>
        # When phantom is ready, make a request for a new task
        @_socket.send(JSON.stringify({
            action: "queueItemRequest"
        }))

# Holds a task in the queue
class QueueItem extends events.EventEmitter
    constructor: (id, request, timeout) ->
        # The unique ID of the item
        @id = id

        # The request contents
        @request = request

        # The response contents
        @response = null

        # The timeout for the item, which re-enqueues it
        @timeout = null

    start: (timeout) ->
        # Start the timeout
        @timeout = setTimeout(@_timeout, timeout)

    finish: (response) ->
        # Close the timeout and set the response
        if @timeout then clearTimeout(@timeout)
        @response = response
        @emit("response")

    _timeout: () =>
        # Emit the timeout event
        @emit("timeout")

exports.create = create
exports.createQueued = createQueued
exports.PhantomClusterServer = PhantomClusterServer
exports.PhantomClusterClient = PhantomClusterClient
exports.PhantomQueuedClusterServer = PhantomQueuedClusterServer
exports.PhantomQueuedClusterClient = PhantomQueuedClusterClient
