module LLMBenchMCPServer

using ClaudeMCPTools
using JSON
using Dates

export LLMBenchServer, SetupProblemTool, GradeProblemTool
export main

# Include components
include("tools/setup_problem.jl")
include("tools/grade_problem.jl")
include("server.jl")

end # module LLMBenchMCPServer
