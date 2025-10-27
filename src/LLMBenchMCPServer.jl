module LLMBenchMCPServer

using ClaudeMCPTools
using JSON
using Dates
using Sockets
using Test

import ClaudeMCPTools: execute, tool_schema

export LLMBenchServer, SetupProblemTool, GradeProblemTool, ListProblemsTool
export main, run_socket_server
export has_sandbox_support, create_sandbox_config, launch_in_sandbox, launch_sandbox_bash

# Include components
include("sandbox_stubs.jl")
include("tools/setup_problem.jl")
include("tools/grade_problem.jl")
include("tools/list_problems.jl")
include("server.jl")

"""
    run_socket_server(socket_path::String; kwargs...)

Run the LLMBenchMCPServer on a Unix domain socket.

# Arguments
- `socket_path`: Path to the Unix socket file
- `setup_fn`: Function to setup problems (optional)
- `grade_fn`: Function to grade solutions (optional)
- `verbose`: Enable verbose logging (default: false)
- `use_revise`: Enable Revise.jl for hot-reloading (default: false)
"""
function run_socket_server(socket_path::String;
    setup_fn::Union{Nothing,Function}=nothing,
    grade_fn::Union{Nothing,Function}=nothing,
    list_fn::Union{Nothing,Function}=nothing,
    verbose::Bool=false,
    use_revise::Bool=false)
    # Create the server
    server = LLMBenchServer(setup_fn=setup_fn, grade_fn=grade_fn, list_fn=list_fn)

    # Run on Unix socket
    run_server_with_revise(server, socket_path; verbose=verbose, use_revise=use_revise)
end

end # module LLMBenchMCPServer
