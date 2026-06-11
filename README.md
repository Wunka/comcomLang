# A compiler that ~tba~ translates to the language format used by: https://github.com/alexsuperzocker/comcomcom

Uses Zig-like syntax, and the goal is that the code remains valid Zig code.
Two modules are provided. `builtin` and `std`
`builtin` functions are special cased and maybe directly mapped to comcomcom functions / zig functions.
`std` is the languages standart library as the normal zig std is not supported.

(much of the main code is inspired / copied from: https://github.com/PixelGuys/Cubyz-linter)