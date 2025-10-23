# Test auto mode functionality
using Test
using LLMBenchMCPServer
using LLMBenchSimple
using ClaudeMCPTools

# Create a test module 
module TestAutoModule
    using LLMBenchSimple
    
    @bench "test_problem" promptval"What is 2+2?" == 4
end

@testset "Auto Mode" begin
    @testset "Auto mode wrapper functions" begin
        # Create wrapper functions similar to what auto mode does
        function test_auto_setup_problem(workdir::String, problem_id::String="")
            if isempty(problem_id)
                return "Error: problem_id is required in auto mode. Format: ModuleName-problem_id"
            end
            
            # Extract module name from problem_id
            parts = split(problem_id, "-", limit=2)
            if length(parts) < 2
                return "Error: Invalid problem_id format. Expected: ModuleName-problem_id, got: $problem_id"
            end
            
            mod_name = parts[1]
            clean_problem_id = parts[2]
            
            # Try to load the module
            try
                mod_symbol = Symbol(mod_name)
                target_mod = Base.require(Main, mod_symbol)
                
                # Check if the module has setup_problem
                if !isdefined(target_mod, :setup_problem)
                    return "Error: Module $mod_name does not export setup_problem function"
                end
                
                # Call the module's setup_problem with the clean problem_id
                setup_fn = getfield(target_mod, :setup_problem)
                return Base.invokelatest(setup_fn, workdir, clean_problem_id)
            catch e
                io = IOBuffer()
                showerror(io, e, catch_backtrace())
                return "Error loading module $mod_name: " * String(take!(io))
            end
        end
        
        function test_auto_grade(workdir::String, transcript::String, problem_id::String="")
            if isempty(problem_id)
                return Dict(
                    "score" => 0.0,
                    "metadata" => Dict("error" => "Error: problem_id is required in auto mode. Format: ModuleName-problem_id")
                )
            end
            
            # Extract module name from problem_id
            parts = split(problem_id, "-", limit=2)
            if length(parts) < 2
                return Dict(
                    "score" => 0.0,
                    "metadata" => Dict("error" => "Error: Invalid problem_id format. Expected: ModuleName-problem_id, got: $problem_id")
                )
            end
            
            mod_name = parts[1]
            clean_problem_id = parts[2]
            
            # Try to load the module
            try
                mod_symbol = Symbol(mod_name)
                target_mod = Base.require(Main, mod_symbol)
                
                # Check if the module has grade
                if !isdefined(target_mod, :grade)
                    return Dict(
                        "score" => 0.0,
                        "metadata" => Dict("error" => "Error: Module $mod_name does not export grade function")
                    )
                end
                
                # Call the module's grade with the clean problem_id
                grade_fn = getfield(target_mod, :grade)
                return Base.invokelatest(grade_fn, workdir, transcript, clean_problem_id)
            catch e
                io = IOBuffer()
                showerror(io, e, catch_backtrace())
                return Dict(
                    "score" => 0.0,
                    "metadata" => Dict("error" => "Error loading module $mod_name: " * String(take!(io)))
                )
            end
        end
        
        # Test auto_setup_problem
        mktempdir() do tmpdir
            # Test with proper format
            result = test_auto_setup_problem(tmpdir, "TestAutoModule-test_problem")
            @test occursin("What is 2+2?", result)
            @test occursin("<answer>", result)
            
            # Test with missing problem_id
            result = test_auto_setup_problem(tmpdir, "")
            @test occursin("Error: problem_id is required", result)
            
            # Test with invalid format
            result = test_auto_setup_problem(tmpdir, "invalid_format")
            @test occursin("Error: Invalid problem_id format", result)
        end
        
        # Test auto_grade
        mktempdir() do tmpdir
            # Test with proper format and correct answer
            transcript = "<answer>4</answer>"
            result = test_auto_grade(tmpdir, transcript, "TestAutoModule-test_problem")
            @test result["score"] == 1.0
            
            # Test with incorrect answer
            transcript = "<answer>5</answer>"
            result = test_auto_grade(tmpdir, transcript, "TestAutoModule-test_problem")
            @test result["score"] == 0.0
            
            # Test with missing problem_id
            result = test_auto_grade(tmpdir, transcript, "")
            @test result["score"] == 0.0
            @test haskey(result, "metadata")
            @test occursin("Error: problem_id is required", result["metadata"]["error"])
            
            # Test with invalid format
            result = test_auto_grade(tmpdir, transcript, "invalid_format")
            @test result["score"] == 0.0
            @test haskey(result, "metadata")
            @test occursin("Error: Invalid problem_id format", result["metadata"]["error"])
            
            # Test with non-existent module
            result = test_auto_grade(tmpdir, transcript, "NonExistentModule-test")
            @test result["score"] == 0.0
            @test haskey(result, "metadata")
            @test occursin("Error loading module", result["metadata"]["error"])
        end
    end
    
    @testset "Auto mode server creation" begin
        # Test that we can create a server in auto mode
        server = LLMBenchServer(
            name="auto-MCP",
            version="1.0.0",
            include_basic_tools=false
        )
        
        # Should have no setup/grade tools initially since they are set via wrappers
        @test !haskey(server.tools, "setup_problem")
        @test !haskey(server.tools, "grade_problem")
    end
end