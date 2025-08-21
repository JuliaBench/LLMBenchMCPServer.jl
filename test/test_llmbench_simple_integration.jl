@testset "LLMBenchSimple Integration" begin
    # Create a test module using LLMBenchSimple
    mktempdir() do tmpdir
        module_file = joinpath(tmpdir, "SimpleBenchModule.jl")
        
        write(module_file, """
        module SimpleBenchModule
        
        # Note: We can't use the prompt"..." macro directly in dynamically created code
        # So we'll manually set up the benchmarks
        import LLMBenchSimple
        
        # Create module-local benchmarks
        const BENCHMARKS = Dict{String, Any}()
        
        function __init__()
            # Clear any existing benchmarks
            empty!(BENCHMARKS)
            
            # Add benchmarks manually
            BENCHMARKS["math1"] = (
                prompt_expr = :(LLMBenchSimple.PromptPlaceholder("What is 5 + 3?") == 8),
                original_expr = nothing
            )
            
            BENCHMARKS["math2"] = (
                prompt_expr = :(LLMBenchSimple.PromptPlaceholder("What is 10 - 4?") == 6),
                original_expr = nothing
            )
        end
        
        # Create wrapper functions that use our module's benchmarks
        function setup_problem(workdir::String, problem_id::String="")
            return LLMBenchSimple._setup_problem_impl(@__MODULE__, workdir, problem_id)
        end
        
        function grade(workdir::String, transcript::String, problem_id::String="")
            return LLMBenchSimple._grade_impl(@__MODULE__, workdir, transcript, problem_id)
        end
        
        end # module
        """)
        
        # Load the module
        include(module_file)
        
        @testset "Module with LLMBenchSimple functions" begin
            # Get the module
            mod = Main.SimpleBenchModule
            
            # Initialize the module to set up benchmarks
            Base.invokelatest(mod.__init__)
            
            mktempdir() do workdir
                # Test setup_problem with empty problem_id (should return error)
                description = Base.invokelatest(mod.setup_problem, workdir, "")
                @test occursin("problem_id is required", description)
                @test occursin("math1", description)
                @test occursin("math2", description)
                
                # Test setup_problem for specific problem
                description = Base.invokelatest(mod.setup_problem, workdir, "math1")
                @test occursin("5 + 3", description)
                @test !occursin("10 - 4", description)
                
                # Test grading with correct answers
                result = Base.invokelatest(mod.grade, workdir, "8", "math1")
                @test result["score"] == 1.0
                
                result = Base.invokelatest(mod.grade, workdir, "6", "math2")
                @test result["score"] == 1.0
                
                # Test grading with incorrect answer
                result = Base.invokelatest(mod.grade, workdir, "7", "math1")
                @test result["score"] == 0.0
                
                # Test grading with empty problem_id (should return error)
                result = Base.invokelatest(mod.grade, workdir, "8", "")
                @test result["score"] == 0.0
                @test occursin("problem_id is required", result["details"])
            end
        end
        
        @testset "Integration with LLMBenchServer" begin
            # Initialize the module
            Base.invokelatest(Main.SimpleBenchModule.__init__)
            
            mktempdir() do workdir
                # Create server using the module's functions (wrapped for world age)
                setup_wrapper = (wd, pid="") -> Base.invokelatest(Main.SimpleBenchModule.setup_problem, wd, pid)
                grade_wrapper = (wd, t, pid="") -> Base.invokelatest(Main.SimpleBenchModule.grade, wd, t, pid)
                
                server = LLMBenchMCPServer.LLMBenchServer(
                    name="SimpleBenchModule",
                    setup_fn=setup_wrapper,
                    grade_fn=grade_wrapper,
                    working_dir=workdir
                )
                
                # Test setup through MCP
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "setup_problem",
                        "arguments" => Dict()
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                # When no problem_id is provided, it should return an error message listing available problems
                @test occursin("problem_id is required", response["result"]["content"][1]["text"])
                @test occursin("math1", response["result"]["content"][1]["text"])
                @test occursin("math2", response["result"]["content"][1]["text"])
                
                # Test grading through MCP
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict("transcript" => "8")  # Answer to first problem
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                grade_result = JSON.parse(response["result"]["content"][1]["text"])
                
                # Should have graded both problems
                @test haskey(grade_result, "subscores")
                @test grade_result["subscores"]["math1"] == 1.0  # Correct
                @test grade_result["subscores"]["math2"] == 0.0  # Incorrect
            end
        end
    end
end