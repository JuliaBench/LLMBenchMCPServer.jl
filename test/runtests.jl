using LLMBenchMCPServer
using ClaudeMCPTools
using Test
using JSON

# Import LLMBenchSimple if available
try
    using LLMBenchSimple
catch
end

@testset "LLMBenchMCPServer.jl" begin
    include("test_setup_problem.jl")
    include("test_grade_problem.jl")
    include("test_server.jl")
    include("test_example_benchmark.jl")
    include("test_output_directories.jl")
    include("test_output_dirs_cli.jl")

    # Only include if LLMBenchSimple is available
    if @isdefined(LLMBenchSimple)
        include("test_llmbench_simple_integration.jl")
    end
end