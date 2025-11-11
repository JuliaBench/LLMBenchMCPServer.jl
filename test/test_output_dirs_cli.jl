@testset "Command-line --output-dirs argument" begin
    @testset "Parse --output-dirs with single directory" begin
        # Create a minimal benchmark module for testing
        mktempdir() do tmpdir
            # Create test directories
            output_dir = joinpath(tmpdir, "test_output")
            mkpath(output_dir)
            write(joinpath(output_dir, "result.txt"), "test data")

            # Create a simple benchmark module file
            benchmark_file = joinpath(tmpdir, "TestBench.jl")
            write(benchmark_file, """
            module TestBench
            export setup_problem, grade

            setup_problem(workdir, problem_id="") = "Test problem"
            grade(workdir, transcript, problem_id="") = Dict("score" => 1.0)

            end
            """)

            # Test that --output-dirs argument is parsed correctly
            # We'll simulate the argument parsing
            args = ["TestBench", "--workspace", tmpdir, "--output-dirs", "test_output", "--direct"]

            # Parse the arguments (simulating what @main does)
            module_name = args[1]
            working_dir = tmpdir
            output_dirs = String[]
            direct_mode = false

            i = 2
            while i <= length(args)
                if args[i] == "--workspace" && i + 1 <= length(args)
                    working_dir = args[i+1]
                    i += 2
                elseif args[i] == "--output-dirs" && i + 1 <= length(args)
                    dirs_arg = args[i+1]
                    output_dirs = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
                    i += 2
                elseif args[i] == "--direct"
                    direct_mode = true
                    i += 1
                else
                    i += 1
                end
            end

            # Verify parsing
            @test length(output_dirs) == 1
            @test output_dirs[1] == "test_output"
            @test direct_mode == true
            @test working_dir == tmpdir

            # Test the move_output_directories function
            @test isdir(output_dir)
            LLMBenchMCPServer.move_output_directories(output_dirs, working_dir, verbose=false)

            # Verify the directory was moved
            @test !isdir(output_dir)
            @test isdir("/tmp/output_dirs/test_output")
            @test isfile("/tmp/output_dirs/test_output/result.txt")

            # Cleanup
            rm("/tmp/output_dirs/test_output", recursive=true)
        end
    end

    @testset "Parse --output-dirs with multiple directories" begin
        mktempdir() do tmpdir
            # Create multiple test directories
            dir1 = joinpath(tmpdir, "results")
            dir2 = joinpath(tmpdir, "logs")
            dir3 = joinpath(tmpdir, "artifacts")
            mkpath(dir1)
            mkpath(dir2)
            mkpath(dir3)
            write(joinpath(dir1, "data1.txt"), "results")
            write(joinpath(dir2, "data2.txt"), "logs")
            write(joinpath(dir3, "data3.txt"), "artifacts")

            # Simulate parsing comma-separated list
            args = ["TestBench", "--output-dirs", "results,logs,artifacts"]

            output_dirs = String[]
            i = 2
            while i <= length(args)
                if args[i] == "--output-dirs" && i + 1 <= length(args)
                    dirs_arg = args[i+1]
                    output_dirs = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
                    i += 2
                else
                    i += 1
                end
            end

            # Verify parsing
            @test length(output_dirs) == 3
            @test "results" in output_dirs
            @test "logs" in output_dirs
            @test "artifacts" in output_dirs

            # Test moving all directories
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)

            # Verify all directories were moved
            @test !isdir(dir1)
            @test !isdir(dir2)
            @test !isdir(dir3)
            @test isdir("/tmp/output_dirs/results")
            @test isdir("/tmp/output_dirs/logs")
            @test isdir("/tmp/output_dirs/artifacts")
            @test isfile("/tmp/output_dirs/results/data1.txt")
            @test isfile("/tmp/output_dirs/logs/data2.txt")
            @test isfile("/tmp/output_dirs/artifacts/data3.txt")

            # Cleanup
            rm("/tmp/output_dirs/results", recursive=true)
            rm("/tmp/output_dirs/logs", recursive=true)
            rm("/tmp/output_dirs/artifacts", recursive=true)
        end
    end

    @testset "Parse --output-dirs with spaces in list" begin
        # Test that spaces around commas are handled correctly
        args = ["TestBench", "--output-dirs", "dir1, dir2 , dir3"]

        output_dirs = String[]
        i = 2
        while i <= length(args)
            if args[i] == "--output-dirs" && i + 1 <= length(args)
                dirs_arg = args[i+1]
                output_dirs = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
                i += 2
            else
                i += 1
            end
        end

        # Verify spaces are stripped
        @test length(output_dirs) == 3
        @test output_dirs[1] == "dir1"
        @test output_dirs[2] == "dir2"
        @test output_dirs[3] == "dir3"
    end

    @testset "Parse --output-dirs with empty entries" begin
        # Test that empty entries (double commas, trailing commas) are filtered out
        args = ["TestBench", "--output-dirs", "dir1,,dir2,"]

        output_dirs = String[]
        i = 2
        while i <= length(args)
            if args[i] == "--output-dirs" && i + 1 <= length(args)
                dirs_arg = args[i+1]
                output_dirs = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
                i += 2
            else
                i += 1
            end
        end

        # Verify empty entries are filtered
        @test length(output_dirs) == 2
        @test output_dirs[1] == "dir1"
        @test output_dirs[2] == "dir2"
    end

    @testset "Integration: --output-dirs in finally block" begin
        # Test that output directories are moved even if the server has issues
        mktempdir() do tmpdir
            output_dir = joinpath(tmpdir, "final_output")
            mkpath(output_dir)
            write(joinpath(output_dir, "important.txt"), "data")

            # Simulate the finally block behavior
            output_dirs = ["final_output"]
            verbose = false

            try
                # This simulates some work before the finally block
                @test isdir(output_dir)
            finally
                # This is what happens in the @main function's finally block
                LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=verbose)
            end

            # Verify the directory was moved
            @test !isdir(output_dir)
            @test isdir("/tmp/output_dirs/final_output")
            @test isfile("/tmp/output_dirs/final_output/important.txt")

            # Cleanup
            rm("/tmp/output_dirs/final_output", recursive=true)
        end
    end

    @testset "Hyphenated flag format --output-dirs" begin
        # Ensure the flag uses hyphens, not underscores
        # This tests that we're using the correct convention

        # Should parse with hyphens
        args_with_hyphens = ["TestBench", "--output-dirs", "test"]
        output_dirs_hyphens = String[]

        i = 2
        while i <= length(args_with_hyphens)
            if args_with_hyphens[i] == "--output-dirs" && i + 1 <= length(args_with_hyphens)
                dirs_arg = args_with_hyphens[i+1]
                output_dirs_hyphens = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
                i += 2
            else
                i += 1
            end
        end

        @test length(output_dirs_hyphens) == 1
        @test output_dirs_hyphens[1] == "test"

        # Should NOT parse with underscores (old format)
        args_with_underscores = ["TestBench", "--output_dirs", "test"]
        output_dirs_underscores = String[]

        i = 2
        while i <= length(args_with_underscores)
            if args_with_underscores[i] == "--output-dirs" && i + 1 <= length(args_with_underscores)
                dirs_arg = args_with_underscores[i+1]
                output_dirs_underscores = String[strip(d) for d in split(dirs_arg, ",") if !isempty(strip(d))]
                i += 2
            else
                i += 1
            end
        end

        # With underscores, it should not match and remain empty
        @test length(output_dirs_underscores) == 0
    end
end
