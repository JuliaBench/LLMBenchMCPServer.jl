@testset "Output Directory Management" begin
    @testset "move_output_directories - basic functionality" begin
        mktempdir() do tmpdir
            # Create test directories with some content
            dir1 = joinpath(tmpdir, "results")
            dir2 = joinpath(tmpdir, "logs")
            mkpath(dir1)
            mkpath(dir2)
            write(joinpath(dir1, "result.txt"), "test result")
            write(joinpath(dir2, "log.txt"), "test log")

            # Move the directories
            output_dirs = ["results", "logs"]
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)

            # Check that directories were moved
            @test !isdir(dir1)
            @test !isdir(dir2)
            @test isdir("/tmp/output_dirs/results")
            @test isdir("/tmp/output_dirs/logs")
            @test isfile("/tmp/output_dirs/results/result.txt")
            @test isfile("/tmp/output_dirs/logs/log.txt")

            # Cleanup
            rm("/tmp/output_dirs/results", recursive=true)
            rm("/tmp/output_dirs/logs", recursive=true)
        end
    end

    @testset "move_output_directories - absolute paths" begin
        mktempdir() do tmpdir
            # Create test directory with absolute path
            dir1 = joinpath(tmpdir, "absolute_test")
            mkpath(dir1)
            write(joinpath(dir1, "file.txt"), "content")

            # Move using absolute path
            output_dirs = [dir1]
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)

            # Check that directory was moved
            @test !isdir(dir1)
            @test isdir("/tmp/output_dirs/absolute_test")
            @test isfile("/tmp/output_dirs/absolute_test/file.txt")

            # Cleanup
            rm("/tmp/output_dirs/absolute_test", recursive=true)
        end
    end

    @testset "move_output_directories - name collision handling" begin
        mktempdir() do tmpdir
            # Create test directory
            dir1 = joinpath(tmpdir, "collision")
            mkpath(dir1)
            write(joinpath(dir1, "file1.txt"), "first")

            # Pre-create destination
            dest1 = "/tmp/output_dirs/collision"
            mkpath(dest1)
            write(joinpath(dest1, "existing.txt"), "existing")

            # Move - should create timestamped directory
            output_dirs = ["collision"]
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)

            # Check that original destination is unchanged
            @test isdir(dest1)
            @test isfile(joinpath(dest1, "existing.txt"))

            # Check that new directory was created with timestamp
            output_dir_contents = readdir("/tmp/output_dirs")
            timestamped_dirs = filter(x -> startswith(x, "collision_"), output_dir_contents)
            @test length(timestamped_dirs) >= 1

            # Cleanup
            for dir in timestamped_dirs
                rm(joinpath("/tmp/output_dirs", dir), recursive=true)
            end
            rm(dest1, recursive=true)
        end
    end

    @testset "move_output_directories - empty list" begin
        mktempdir() do tmpdir
            # Should handle empty list gracefully
            output_dirs = String[]
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)
            @test true  # Just ensure no error
        end
    end

    @testset "move_output_directories - nonexistent directory" begin
        mktempdir() do tmpdir
            # Should handle nonexistent directory gracefully
            output_dirs = ["nonexistent"]

            # Just test that it doesn't throw an error
            # The warning goes to stderr but we don't need to capture it for testing
            @test_nowarn LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)
        end
    end

    @testset "move_output_directories - creates output base" begin
        # Ensure /tmp/output_dirs doesn't exist
        output_base = "/tmp/output_dirs"
        if isdir(output_base)
            rm(output_base, recursive=true)
        end

        mktempdir() do tmpdir
            dir1 = joinpath(tmpdir, "test")
            mkpath(dir1)

            # Move should create the output base directory
            output_dirs = ["test"]
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=false)

            @test isdir(output_base)
            @test isdir(joinpath(output_base, "test"))

            # Cleanup
            rm(joinpath(output_base, "test"), recursive=true)
        end
    end

    @testset "move_output_directories - verbose mode" begin
        mktempdir() do tmpdir
            dir1 = joinpath(tmpdir, "verbose_test")
            mkpath(dir1)

            # Test that verbose mode runs without throwing an exception
            output_dirs = ["verbose_test"]
            LLMBenchMCPServer.move_output_directories(output_dirs, tmpdir, verbose=true)

            # Verify it actually moved the directory
            @test !isdir(dir1)
            @test isdir("/tmp/output_dirs/verbose_test")

            # Cleanup
            rm("/tmp/output_dirs/verbose_test", recursive=true)
        end
    end
end
