//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Tools to manipulate 4D ubyte vectors as RGBA colors.
module gl3n_extra.color;


import std.traits;

import gl3n_extra.linalg;


/// 8-bit RGBA color.
alias Color = vec4ub;


/// Construct an RGBA color from individual channels.
Color rgba(I)(I r, I g, I b, I a) @safe pure nothrow @nogc
    if(isIntegral!I)
{
    assert(r >= 0 && r <= ubyte.max &&
           g >= 0 && g <= ubyte.max &&
           b >= 0 && b <= ubyte.max &&
           a >= 0 && a <= ubyte.max , "Color channels out of range");
    return Color(cast(ubyte)r, cast(ubyte)g, cast(ubyte)b, cast(ubyte)a);
}

/// Construct an RGB (RGBA with full alpha) color from individual channels.
Color rgb(I)(I r, I g, I b) @safe pure nothrow @nogc
    if(isIntegral!I)
{
    return rgba(r, g, b, 255);
}

import std.ascii: toUpper, isHexDigit;
import std.string;

/// RGB color from a hexadecimal string (CSS style), e.g. FFFFFF for white.
template rgb(string c) if(c.length == 6 && c.count!isHexDigit == 6)
{
    enum auto rgb = rgba!(c ~ "FF");
}

/// RGBA color from a hexadecimal string (CSS style), e.g. FFFFFF80 for half-transparent white.
Color rgba(string c)() @safe pure nothrow @nogc
    if(c.length == 8 && c.count!isHexDigit == 8)
{
    // Funcs to parse one digit and a 2-digit channel.
    enum digit   = (char d) => d >= '0' && d <= '9' ? d - '0' : 10 + d.toUpper - 'A';
    enum channel = (string hex) => cast(ubyte)(16 * digit(hex[0]) + digit(hex[1]));
    return Color(channel(c[0 .. 2]), channel(c[2 .. 4]), 
                 channel(c[4 .. 6]), channel(c[6 .. 8]));
}
