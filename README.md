# LLMBenchMCPServer.jl

[![CI](https://github.com/JuliaComputing/LLMBenchMCPServer.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaComputing/LLMBenchMCPServer.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/JuliaComputing/LLMBenchMCPServer.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaComputing/LLMBenchMCPServer.jl)

A Julia package that implements the full taiga spec as an MCP (Model Context Protocol) server for LLM benchmarking.

## Features

- Complete MCP server implementation for LLM benchmarking
- Support for problem setup and grading functions
- Integration with ClaudeMCPTools for bash and file editing capabilities
- Flexible module-based benchmark loading

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaComputing/LLMBenchMCPServer.jl")
```

## Usage

### Basic Server Setup

```julia
using LLMBenchMCPServer

# Define setup and grade functions
function setup_problem(workdir::String)
    # Create problem files and return instructions
    return "Solve this problem..."
end

function grade(workdir::String, transcript::String)
    # Grade the solution based on transcript
    return Dict(
        "subscores" => Dict("correctness" => 0.8),
        "weights" => Dict("correctness" => 1.0),
        "score" => 0.8
    )
end

# Create and run server
server = LLMBenchServer(
    setup_fn=setup_problem,
    grade_fn=grade
)

# Run as stdio server
run_stdio_server(server)
```

### Module-Based Execution

#### Command Line Usage

```bash
# Using the -m flag (recommended)
julia --project -m LLMBenchMCPServer MyBenchmarkModule [options]

# Or using -e flag
julia --project -e 'using LLMBenchMCPServer; LLMBenchMCPServer.main()' -- MyBenchmarkModule [options]
```

Options:
- `--workdir PATH`: Set the working directory (default: current directory)
- `--no-basic-tools`: Disable basic tools (bash, str_replace_editor)
- `--verbose`: Enable verbose output
- `--help, -h`: Show help message

#### Programmatic Usage

```julia
# Run with a benchmark module
# The module must export setup_problem and grade functions
LLMBenchMCPServer.main(["MyBenchmarkModule", "--verbose"])
```

### Creating a Benchmark Module

#### Option 1: Using LLMBenchSimple

```julia
module MyBenchmark
    using LLMBenchSimple
    
    @bench "addition" prompt"What is 2 + 2?" == 4
    @bench "capital" prompt"What is the capital of France?" == "Paris"
end
```

#### Option 2: Custom Implementation

```julia
module MyBenchmark

export setup_problem, grade

function setup_problem(workdir::String)
    problem_file = joinpath(workdir, "problem.txt")
    write(problem_file, "What is 2 + 2?")
    
    return """
    # Math Problem
    Solve the problem in problem.txt
    Write your answer to answer.txt
    """
end

function grade(workdir::String, transcript::String)
    answer_file = joinpath(workdir, "answer.txt")
    
    if !isfile(answer_file)
        return Dict("score" => 0.0, "details" => "No answer file")
    end
    
    answer = strip(read(answer_file, String))
    
    if answer == "4"
        return Dict("score" => 1.0, "details" => "Correct!")
    else
        return Dict("score" => 0.0, "details" => "Incorrect")
    end
end

end # module
```

## MCP Tools Available

- `setup_problem`: Initialize a problem in the working directory
- `grade_problem`: Grade a solution based on the transcript
- `bash`: Execute bash commands (if included)
- `str_replace_editor`: Edit files (if included)

## API

### LLMBenchServer

```julia
LLMBenchServer(;
    name::String = "LLMBenchServer",
    version::String = "1.0.0",
    setup_fn::Union{Function, Nothing} = nothing,
    grade_fn::Union{Function, Nothing} = nothing,
    working_dir::String = pwd(),
    include_basic_tools::Bool = true
)
```

Creates an MCP server configured for LLM benchmarking.

### Grade Function Return Format

The grade function should return either:
- A `Number` (simple score)
- A `Dict` with:
  - `subscores`: Dict of component scores
  - `weights`: Dict of component weights
  - `score`: Total score (auto-calculated if not provided)
  - `details`: Optional string with grading details

## License

MIT