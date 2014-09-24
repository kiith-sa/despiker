//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Functionality extending gl3n.linalg
module gl3n_extra.linalg;

public import gl3n.linalg;


/// Readability shortcuts.
alias Vector!(uint, 2) vec2u;
alias Vector!(uint, 3) vec3u;
alias Vector!(uint, 4) vec4u;
alias Vector!(ubyte, 2) vec2ub;
alias Vector!(ubyte, 3) vec3ub;
alias Vector!(ubyte, 4) vec4ub;
alias Matrix!(float, 3, 2) mat32;
alias Matrix!(float, 4, 2) mat42;
alias Matrix!(float, 2, 3) mat23;
alias Matrix!(float, 4, 3) mat43;
alias Matrix!(float, 2, 4) mat24;
alias Matrix!(double, 2, 2) mat2d;
alias Matrix!(double, 3, 3) mat3d;
alias Matrix!(double, 4, 4) mat4d;
alias Matrix!(double, 3, 2) mat32d;
alias Matrix!(double, 4, 2) mat42d;
alias Matrix!(double, 2, 3) mat23d;
alias Matrix!(double, 4, 3) mat43d;
alias Matrix!(double, 2, 4) mat24d;
alias Matrix!(double, 3, 4) mat34d;

// Called setLength() because length() doesn't seem to work correctly with UFCS.
/// Set length of the vector, resizing it but preserving its direction.
void setLength(T, size_t dim)(ref Vector!(T, dim) vector, T length) @safe pure nothrow @nogc
{
    const oldLength = vector.length;
    assert(oldLength != 0.0f, "Cannot set length of a zero vector!");
    const ratio = length / oldLength;
    vector *= ratio;
}
