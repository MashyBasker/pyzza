# pyzza

A small Python interpreter written in Zig. Pipeline: tokenizer → parser (AST) → bytecode compiler → stack-based VM.

## Usage

```
zig build run -- <file.py>      # run a script
zig build run -- --test [dir]   # tokenize/parse/compile/run every .py file in dir (default: tests/fixtures)
zig build test                  # run inline unit tests
```

## TODO

- [x] `print(...)` with multiple args
- [x] `if` / `elif` / `else`
- [x] `for x in <expr>:` loops (over list literals)
- [x] Arithmetic and comparison expressions with correct precedence
- [x] List literals
- [x] String concatenation via `+`
- [ ] `while` loops, `break`, `continue`
- [ ] Boolean operators `and`, `or`, `not`
- [ ] `True`, `False`, `None` literals
- [ ] Function definitions (`def`) and calls — call expressions currently parse but the compiler rejects them
- [ ] Classes / object model
- [ ] Exceptions (`try`/`except`/`finally`)
- [ ] Augmented assignment (`+=`, `-=`, ...)
- [ ] Tuple/multiple assignment (`a, b = 1, 2`)
- [ ] Dict and set literals, indexing/slicing (`x[0]`, `x[1:2]`)
- [ ] Attribute access (`x.y`)
- [ ] Integer vs. float distinction (numbers are all `f64` right now)
- [ ] Built-in functions (`len`, `range`, `str`, ...) and a minimal standard library
- [ ] String escape sequences, f-strings
- [ ] Source-location-aware runtime errors (currently just an error name, no line number)
