# Bedrock

Bedrock is statically typed safe systems programming language designed around simplicity, readability, and practicality.
Memory is managed automatically through a **region-based memory model**. For raw pointers manipulation and non-memory safe regions we also have `unsafe` block support, such as for C interoperability an unsafe block is required.
Bedrock intentionally avoids object-oriented programming. Programs are built using procedures, functions, structs, and modules instead of classes or inheritance.

## Building and testing
Compiler dependencies
- Zig 0.16.0
- LLVM 22.1.8

```bash
# building the compiler
zig build
# run compiler tests
zig build test --summary all
# jit compiled a bedrock program
zig build run -- corpus/codegen/<file_name>.bok --jit
```

## Compiler usage
```
bok --help
```

> the binary is found in `zig-out/bin`
