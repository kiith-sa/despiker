module gfmod.core.text;

import std.file,
       std.utf,
       std.conv,
       std.encoding,
       std.array,
       core.stdc.string;


/**
 * Sanitize a C string from a library.
 *
 * Params:
 * 
 * inputZ = Zero-terminated string to sanitize.
 * output = Sanitized ASCII string will be written here. Non-ASCII bytes are replaced by '?'
 *
 * Returns: false if at least one character was invalid, true otherwise.
 */
bool sanitizeASCIIInPlace(char[] inputZ) @trusted pure nothrow @nogc
{
    assert(inputZ !is  null);
    bool allValid = true;
    foreach(i; 0 .. inputZ.length) if(inputZ[i] >= 0x80)
    {
        allValid = false;
        inputZ[i]    = '?';
    }
    return allValid;
}

