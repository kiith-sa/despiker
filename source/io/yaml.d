//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// YAML utilities.
module io.yaml;


public import dyaml.all;
alias YAMLNode = Node;


/** Dump YAML to a string and return the string.
 *
 * Inefficient and GC-intensive at the moment, use with care.
 */
string dumpToString(YAMLNode yaml) @trusted nothrow
{
    import std.exception;
    import std.stream;
    auto stream = new MemoryStream().assumeWontThrow;
    Dumper(stream).dump(yaml).assumeWontThrow;
    return cast(string)stream.data.assumeWontThrow;
}
