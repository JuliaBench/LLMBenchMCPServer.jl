# Create a test module directly
module SimpleBenchModule
    using LLMBenchSimple: _setup_problem_impl, _grade_impl, PromptPlaceholder
    
    # Create module-local benchmarks
    const BENCHMARKS = Dict{String, Any}()
    
    function __init__()
        # Clear any existing benchmarks
        empty!(BENCHMARKS)
        
        # Add benchmarks manually
        BENCHMARKS["math1"] = (
            prompt_expr = :(PromptPlaceholder("What is 5 + 3?") == 8),
            original_expr = nothing
        )
        
        BENCHMARKS["math2"] = (
            prompt_expr = :(PromptPlaceholder("What is 10 - 4?") == 6),
            original_expr = nothing
        )
    end
    
    # Create wrapper functions that use our module's benchmarks
    function setup_problem(workdir::String, problem_id::String="")
        return _setup_problem_impl(@__MODULE__, workdir, problem_id)
    end
    
    function grade(workdir::String, transcript::String, problem_id::String="")
        return _grade_impl(@__MODULE__, workdir, transcript, problem_id)
    end
end # module

@testset "LLMBenchSimple Integration" begin
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
                result = Base.invokelatest(mod.grade, workdir, "<answer>8</answer>", "math1")
                if result["score"] != 1.0
                    @info "Grade result for math1 with answer 8" result
                end
                @test result["score"] == 1.0
                
                result = Base.invokelatest(mod.grade, workdir, "<answer>6</answer>", "math2")
                if result["score"] != 1.0
                    @info "Grade result for math2 with answer 6" result
                end
                @test result["score"] == 1.0
                
                # Test grading with incorrect answer
                result = Base.invokelatest(mod.grade, workdir, "<answer>7</answer>", "math1")
                @test result["score"] == 0.0
                
                # Test grading with empty problem_id (should return error)
                result = Base.invokelatest(mod.grade, workdir, "<answer>8</answer>", "")
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
                
                # Test grading through MCP for math1
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict(
                            "transcript" => "<answer>8</answer>",
                            "problem_id" => "math1"
                        )
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                grade_result = JSON.parse(response["result"]["content"][1]["text"])
                
                # Should have graded math1 correctly
                @test haskey(grade_result, "subscores")
                @test grade_result["subscores"]["math1"] == 1.0  # Correct
                @test grade_result["score"] == 1.0
                
                # Test grading through MCP for math2
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict(
                            "transcript" => "<answer>5</answer>",  # Wrong answer
                            "problem_id" => "math2"
                        )
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                grade_result = JSON.parse(response["result"]["content"][1]["text"])
                
                # Should have graded math2 incorrectly
                @test haskey(grade_result, "subscores")
                @test grade_result["subscores"]["math2"] == 0.0  # Incorrect
                @test grade_result["score"] == 0.0
            end
        end
end