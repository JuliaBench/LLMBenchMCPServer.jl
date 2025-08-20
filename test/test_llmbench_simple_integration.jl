@testset "LLMBenchSimple Integration" begin
    # Create a test module using LLMBenchSimple
    mktempdir() do tmpdir
        module_file = joinpath(tmpdir, "SimpleBenchModule.jl")
        
        write(module_file, """
        module SimpleBenchModule
        
        # Note: We can't use the prompt"..." macro directly in dynamically created code
        # So we'll manually set up the benchmarks
        import LLMBenchSimple
        
        function __init__()
            # Clear any existing benchmarks
            empty!(LLMBenchSimple.BENCHMARKS)
            
            # Add benchmarks manually
            LLMBenchSimple.BENCHMARKS["math1"] = (
                prompt_expr = :(LLMBenchSimple.PromptPlaceholder("What is 5 + 3?") == "8"),
                original_expr = nothing
            )
            
            LLMBenchSimple.BENCHMARKS["math2"] = (
                prompt_expr = :(LLMBenchSimple.PromptPlaceholder("What is 10 - 4?") == "6"),
                original_expr = nothing
            )
        end
        
        # Export the setup and grade functions from LLMBenchSimple
        const setup_problem = LLMBenchSimple.setup_problem
        const grade = LLMBenchSimple.grade
        
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
                # Test setup_problem for all problems
                description = Base.invokelatest(mod.setup_problem, workdir, "")
                @test occursin("math1", description)
                @test occursin("5 + 3", description)
                @test occursin("math2", description)
                @test occursin("10 - 4", description)
                
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
                
                # Test grading all problems (with mixed results)
                result = Base.invokelatest(mod.grade, workdir, "8", "")
                @test haskey(result, "subscores")
                @test result["subscores"]["math1"] == 1.0  # "8" is correct for 5+3
                @test result["subscores"]["math2"] == 0.0  # "8" is incorrect for 10-4
            end
        end
        
        @testset "Integration with LLMBenchServer" begin
            # Initialize the module
            Base.invokelatest(Main.SimpleBenchModule.__init__)
            
            mktempdir() do workdir
                # Create server using the module's functions (wrapped for world age)
                setup_wrapper = (wd) -> Base.invokelatest(Main.SimpleBenchModule.setup_problem, wd, "")
                grade_wrapper = (wd, t) -> Base.invokelatest(Main.SimpleBenchModule.grade, wd, t, "")
                
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
                @test occursin("5 + 3", response["result"]["content"][1]["text"])
                @test occursin("10 - 4", response["result"]["content"][1]["text"])
                
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