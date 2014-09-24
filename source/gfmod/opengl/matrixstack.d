module gfmod.opengl.matrixstack;

import gl3n.linalg;


/** A matrix stack designed to replace fixed-pipeline matrix stacks.
 *
 * This stack always exposes both the top element and its inverse.
 */
class MatrixStack(F, size_t depth = 32)
    if(depth > 0 && (is(F == float) || is(F == double)))
{
private:
    size_t _top; // index of top matrix
    M[depth] _matrices;
    M[depth] _invMatrices;

public:
    /// The matrix type this stack works with.
    alias M = Matrix!(F, 4, 4);

    /// Creates a matrix stack.
    /// The stack is initialized with one element, an identity matrix.
    this() @safe pure nothrow @nogc
    {
        _top = 0;
        loadIdentity();
    }

    /// Replacement for $(D glLoadIdentity).
    void loadIdentity() @safe pure nothrow @nogc
    {
        _matrices[_top]    = M.identity();
        _invMatrices[_top] = M.identity();
    }

    /// Replacement for $(D glPushMatrix).
    void push() @safe pure nothrow @nogc
    {
        if(_top + 1 >= depth) { assert(false, "Matrix stack is full"); }

        _matrices[_top + 1] = _matrices[_top];
        _invMatrices[_top + 1] = _invMatrices[_top];
        ++_top;
    }

    /// Replacement for $(D glPopMatrix).
    void pop() @safe pure nothrow @nogc
    {
        if (_top <= 0) { assert(false, "Matrix stack is empty"); }

        --_top;
    }

    /// Returns: Top matrix.
    /// Replaces $(D glLoadMatrix).
    M top() @safe pure const nothrow @nogc { return _matrices[_top]; }

    /// Returns: Inverse of top matrix.
    M invTop() @safe pure const nothrow @nogc { return _invMatrices[_top]; }

    /// Sets top matrix.
    /// Replaces $(D glLoadMatrix).
    void setTop(M m) @safe pure nothrow @nogc
    {
        _matrices[_top] = m;
        _invMatrices[_top] = m.inverse();
    }

    /// Replacement for $(D glMultMatrix).
    void mult(M m) @safe pure nothrow @nogc { mult(m, m.inverse()); }

    /// Replacement for $(D glMultMatrix), with provided inverse.
    void mult(M m, M invM) @safe pure nothrow @nogc
    {
        _matrices[_top]    = _matrices[_top] * m;
        _invMatrices[_top] = invM *_invMatrices[_top];
    }

    /// Replacement for $(D glTranslate).
    void translate(Vector!(F, 3) v) @safe pure nothrow @nogc { translate(v.x, v.y, v.z); }

    /// Ditto.
    void translate(F x, F y, F z) @safe pure nothrow @nogc
    {
        mult(M.translation(x, y, z), M.translation(-x, -y, -z));
    }

    /// Replacement for $(D glScale).
    void scale(Vector!(F, 3) v) @safe pure nothrow @nogc { scale(v.x, v.y, v.z); }

    /// Replacement for $(D glScale).
    void scale(F x, F y, F z) @safe pure nothrow @nogc
    {
        mult(M.scaling(x, y, z), M.scaling(1 / x, 1 / y, 1 / z));
    }


    /// Replacement for $(D glRotate).
    /// Warning: Angle is given in radians, unlike the original API.
    void rotate(F angle, Vector!(F, 3) axis) @safe pure nothrow @nogc
    {
        M rot = M.rotation(angle, axis);
        mult(rot, rot.transposed()); // inversing a rotation matrix is tranposing
    }

    /// Replacement for $(D gluPerspective).
    void perspective(F left, F right, F bottom, F top, F near, F far)
        @safe pure nothrow @nogc
    {
        mult(M.perspective(left, right, bottom, top, near, far));
    }

    /// Replacement for $(D glOrtho).
    void ortho(F left, F right, F bottom, F top, F near, F far)
        @safe pure nothrow @nogc
    {
        mult(M.orthographic(left, right, bottom, top, near, far));
    }
}

unittest
{
    auto s = new MatrixStack!double();

    s.loadIdentity();
    s.push();
    s.pop();

    s.translate(vec3d(4,5,6));
    s.scale(vec3d(0.5));
}
