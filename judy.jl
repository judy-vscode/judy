using Sockets
import JSON

include("EventHandler.jl")
include("MsgHandler.jl")

server = listen(8000)
sock = accept(server)
client = connect(18001)

while isopen(sock)
  # get events
  msg = MsgHandler.msgRecv(sock)
  result = Dict()
  event = ""

  # handle events
  id, method, params = MsgHandler.msgParse(msg)
  println(method)
  if method == "continue"
    result = EventHandler.continous()

  elseif method == "next"
    EventHandler.stepOver()

  elseif method == "setBreakPoints"
    filePath = params["path"]
    lineno = params["lines"]
    result = EventHandler.setBreakPoints(filePath, lineno)
    event = MsgHandler.eventCreate(Dict("method" => "stopOnBreakpoint",
                              "thread" => 1))

  elseif method == "initialize"
    EventHandler.readSourceToAST(ARGS[1])
    event = MsgHandler.eventCreate(Dict("method" => "initialize"))
    print(client, event)

  elseif method == "launch"
    if !haskey(params, "stopOnEntry")
      EventHandler.run()
    else
      event = MsgHandler.eventCreate(Dict("method" => "stopOnEntry",
                             "thread" => 1))
    end
    print(client, event)

  elseif method == "clearBreakPoints"
    EventHandler.clearBreakPoints()

  else
    # throw(MsgHandler.UnKnownMethod("$(method) can't be called"))
    result = "$method can't be called"
  end

  # prepare respond
  response = MsgHandler.msgCreate(id, result)

  # send events
  write(sock, response)
end