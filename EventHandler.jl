module EventHandler

include("DebugInfo.jl")

mutable struct BreakPoints
  filepath::AbstractString
  lineno::Array{Int64,1}
end

mutable struct AstInfo
  asts::Array
  blocks::Array # save struct BlockInfo
end

mutable struct BlockInfo
  BlockType::Symbol
  startline::Int64
  endline::Int64
  raw_code::AbstractString
end

# FileLine["FileName"] = line number
FileLine = Dict()
# FileAst["filename"] = struct AstInfo
FileAst = Dict()
# FileBp["filename"] = [bp line array]
FileBp = Dict()

currentFile = ""
errors = ""

struct NotImplementedError <: Exception end
struct BreakPointStop <: Exception end

function readSourceToAST(file)
  global asts
  global blocks
  line = 0
  s = ""
  # recording blocks such as a function
  block_start = 0
  block_end = 0
  open(file) do f
    for ln in eachline(f)
      line += 1
      s *= ln
      ex = parseInputLine(s)
      if (isa(ex, Expr) && ex.head === :incomplete)
        s *= "\n"
        if block_start == 0
          block_start = line
        end
        continue
      else
        if block_start != 0
          # add block line postion
          block_end = line
          blockinfo = BlockInfo(ex.head,block_start, block_end,s)
          push!(blocks, blockinfo)
          block_start = 0
        end
        ast = Meta.lower(Main, ex)
        push!(asts, ast)
        s = ""
      end
    end
  end
end


# run whole program
# return a status contains ast, current_line
function run()
  asts = FileAst[currentFile]
  # line = FileLine[currentFile]
  for ast in asts
    try
      updateLine()
      Core.eval(Main, ast)
    catch err
      # if we run to a breakpoint
      # we will catch an exception and collect info
      if err isa BreakPointStop
        Break()
      else
        println(err)
      end
      return
    end
  end
  # exit normally
  return
end

# update info from this point
function Break()
  global line
  println("hit BreakPoint: ", line)
  # collect variable info
  DebugInfo.collectVarInfo()
  # collect stack info
  DebugInfo.collectStackInfo()
end


function stepOver()
  global asts
  global line
  ast_index = getAstIndex(line)
  if ast_index == lastindex(asts) + 1
    return false
  end
  # run next line code
  try
    updateLine()
    Core.eval(Main, asts[ast_index])
  catch err
    # if we meet a breakpoint
    # we just ignore it
    if err isa BreakPointStop
      Break()
      return true
    else
      global errors
      errors = string(err)
      println(errors)
      return false
    end
  end
  # collect information
  Break()
  return true
end

function continous()
  asts = FileAst[currentFile]
  line = FileLine[currentFile]
  ast_index = getAstIndex(line)

  res = Dict("allThreadsContinued" => true)

  for ast in asts[ast_index: end]
    print(ast)
    try
      updateLine()
      Core.eval(Main, ast)
    catch err
      if err isa BreakPointStop
        Break()
      else
        global errors
        errors = string(err)
        println(errors)
      end
      return res
    end
  end
  # exit normally
  return res
end

function stepIn()
  throw(NotImplementedError("step have not been implemented"))
end

function getRealPos(filePath, bpline)
  asts = FileAst[filePath]
    #check if exists bp in block
    #The key to insert the point is when we revise a copy of function's ast,
    #and then eval the ast, we update the definition of the function
    #Another thing is we should make the mapping from original code pos to insert offset
    #considering blank line  
  global blocks
  for blockinfo in blocks
    if blockinfo.startline <= bpline <= blockinfo.endline
      ast = parseInputLine(blockinfo.raw_code)
      codelines = split(blockinfo.raw_code,"\n")
      # for codeline in codelines:
      #   if isempty(strip(codeline))
      nonBlankLine = 0
      firstNonBlankLine = 0
      for i in range(1, stop = blockinfo.endline - blockinfo.startline + 1)
        if isempty(strip(codelines[i]))
          continue
        end
        if i >= bpline - blockinfo.startline + 1
          firstNonBlankLine = i
          break
        end
        nonBlankLine += 1  #nonBlankLine before bp line
      end
      push!(ast.args[2].args, Nothing)
      if nonBlankLine == 0
        ofs = 1
      elseif bpline == blockinfo.endline
        firstNonBlankLine = blockinfo.endline - blockinfo.startline + 1
        ofs = length(ast.args[2].args)
      else
        ofs = 2 * nonBlankLine - 1
      end
      realLineno = firstNonBlankLine + blockinfo.startline - 1
      return ast, ofs, realLineno
    #not in a block
    end
  end

  firstNonBlankLine = bpline
  while true
    ast_index = getAstIndex(firstNonBlankLine)
    if ast_index > length(asts)
      firstNonBlankLine = bpline
      break
    end
    if isa(asts[ast_index], Nothing)
      firstNonBlankLine += 1
    else
      break
    end
  end
  return Nothing, Nothing, firstNonBlankLine
end   


function setBreakPoints(filePath, lineno)
#check current bp
#if bp added, insert BreakPoint
#if canceled, delete Breanpoint


  global bp_list
  global blocks
  global line
  res = []
  # results for adding breakpoints
  
  flag = false
  bp = BreakPoint("",[])
  for e in bp_list
    if e.filepath == filePath
      bp = e
      pre_lineno = e.lineno
      flag = true
    end
  end

  if !flag
    pre_lineno = []
    push!(bp_list, bp)
  
  common = intersect(Set(pre_lineno), Set(lineno))
  increment = collect(setdiff(Set(lineno), common))
  decrement = collect(setdiff(Set(pre_lineno), common))


  id = 1
  for bpline in collect(common)
    push!(res, Dict("verified" => true,
    "line" => bpline,  #verify first non-blank line
    "id" => id))
    id += 1
  #add
  for bpline in increment
    ast, ofs, realLineno = getRealPos(filePath, bpline)
    push!(res, Dict("verified" => true,
    "line" => realLineno,  #verify first non-blank line
    "id" => id))
    id += 1
    if !isa(ast, Nothing)
      ast.args[2].args[ofs] = Expr(:call, Break)
      eval(ast)
    end
    index = findfirst(isequal(bpline), increment)
    print(index)
    increment[i] = realLineno
  end
  #cancel
  for bpline in decrement
    ast, ofs, realLineno = getRealPos(filePath, bpline)
    if !isa(ast, Nothing)
      ast.args[2].args[ofs] = "#= none =#"
      eval(ast)
    end
  end
  new_lineno = collect(common.union(increment))
  bp.lineno = new_lineno
  bp.filepath = filePath
  
  return res
end

# get stack trace for the current collection
function getStackTrace()
  return DebugInfo.getStackInfo()
end


function getScopes(frame_id)
  return Dict("name" => "main",
              "variablesReference" => frame_id)
end


function getVariables(ref)
  return DebugInfo.getVarInfo()
end

function getStatus(reason)
  asts = FileAst[currentFile]
  line = FileLine[currentFile]
  if getAstIndex() == lastindex(asts) + 1
    reason == "exited"
    return Dict("exitCode" => 0), "exited"
  end

  description = ""
  if reason == "step"
    description = "step over (ignore breakpoints)"
  elseif reason == "breakpoint"
    description = "hit breakpoint: " * "$(line)"
  end
  result = Dict("reason" => reason,
                "description" => description,
                "text" => " ")
  return result, "stopped"
end


# update line for run/next/continous call
function updateLine()
  global blocks
  global line
  ofs = 1
  for blockinfo in blocks
    if line == blockinfo.startline
      ofs = blockinfo.endline - blockinfo.startline + 1
      break
    elseif blockinfo.startline > line
      break
    end
  end
  line += ofs
  println("current line:", line)
  if checkBreakPoint(line)
    throw(BreakPointStop())
  end
end

function checkBreakPoint(line)
  global bp_list
  if line in bp.lineno
    return true
  else
    return false
  end
end

# get AstIndex from current line number
function getAstIndex(lineno)
  global blocks
  global asts
  base = lineno
  ofs = 0
  for block in blocks
    if block.startline <= lineno <= block.endline
      base = block.startline
      break
    elseif block.startline > lineno
      break
    end
    ofs += block.endline - block.startline
  end
  return base - ofs
end
  

function parseInputLine(s::String; filename::String="none", depwarn=true)
  # For now, assume all parser warnings are depwarns
  ex = if depwarn
      ccall(:jl_parse_input_line, Any, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
            s, sizeof(s), filename, sizeof(filename))
  else
      with_logger(NullLogger()) do
          ccall(:jl_parse_input_line, Any, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
                s, sizeof(s), filename, sizeof(filename))
      end
  end
  return ex
end

end # module EventHandler