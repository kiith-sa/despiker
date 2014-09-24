//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Axis-aligned bounding boxes. Based on gfm.math.box box, not gl3n.
module gl3n_extra.box;

import gl3n_extra.linalg;

/// N-dimensional half-open interval [a, b[.
struct Box(T, size_t N)
{
@safe @nogc:
    static assert(N > 0);

public:
    alias Vector!(T, N) Bound;

    Bound min; // not enforced, the box can have negative volume
    Bound max;

    /// Construct a box which extends between 2 points.
    /// Boundaries: min is inside the box, max is just outside.
    this(Bound min_, Bound max_) pure nothrow
    {
        foreach(i; 0 .. N)
        {
            min.vector[i] = .min(min_.vector[i], max_.vector[i]);
            max.vector[i] = .max(min_.vector[i], max_.vector[i]);
        }
    }

    static if (N == 1u)
    this(T min_, T max_) pure nothrow
    {
        this(Bound(min_), Bound(max_));
    }

    static if (N == 2u)
    this(T min_x, T min_y, T max_x, T max_y) pure nothrow
    {
        this(Bound(min_x, min_y), Bound(max_x, max_y));
    }

    static if (N == 3u)
    this(T min_x, T min_y, T min_z, T max_x, T max_y, T max_z) pure nothrow
    {
        this(Bound(min_x, min_y, min_z), Bound(max_x, max_y, max_z));
    }


    /// Returns: Dimensions of the box.
    Bound size() pure const nothrow
    {
        return max - min;
    }

    /// Returns: Area of the box.
    T area() pure const nothrow
    {
        return cast(T)size.magnitude_squared;
    }

    /// Returns: Center of the box.
    Bound center() pure const nothrow
    {
        Bound.vt[Bound.dimension] vector = (min.vector[] + max.vector[]) / 2;
        return Bound(vector);
    }

    /// Returns: Width of the box, always applicable.
    static if (N >= 1)
    T width() pure const nothrow
    {
        return max.x - min.x;
    }

    /// Returns: Height of the box, if applicable.
    static if (N >= 2)
    T height() pure const nothrow
    {
        return max.y - min.y;
    }

    /// Returns: Depth of the box, if applicable.
    static if (N >= 3)
    T depth() pure const nothrow
    {
        return max.z - min.z;
    }

    /// Returns: Signed volume of the box.
    T volume() pure const nothrow
    {
        T res = 1;
        Bound size = size();
        foreach(i; 0 .. N) { res *= size.vector[i]; }
        return res;
    }

    /// Returns: true if it contains point.
    bool contains(Bound point) pure const nothrow
    {
        foreach(i; 0 .. N)
        {
            if(!(point.vector[i] >= min.vector[i] && point.vector[i] < max.vector[i]))
            {
                return false;
            }
        }

        return true;
    }

    /// Returns: true if it contains box other.
    bool contains(Box other) pure const nothrow
    {
        assert(isSorted());
        assert(other.isSorted());

        foreach(i; 0 .. N)
        {
            if(other.min.vector[i] >= max.vector[i] || other.max.vector[i] < min.vector[i])
            {
                return false;
            }
        }
        return true;
    }

    /// Euclidean squared distance from a point.
    /// See_also: Numerical Recipes Third Edition (2007)
    double squaredDistance(U)(Vector!(U, N) point) pure const nothrow
    {
        double distanceSquared = 0;
        foreach(i; 0 .. N)
        {
            if(point.vector[i] < min.vector[i])
            {
                distanceSquared += (point.vector[i] - min.vector[i]) ^^ 2;
            }
            if(point.vector[i] > max.vector[i])
            {
                distanceSquared += (point.vector[i] - max.vector[i]) ^^ 2;
            }
        }
        return distanceSquared;
    }

    /// Euclidean distance from a point.
    /// See_also: squaredDistance.
    double distance(U)(Vector!(U, N) point)
    {
        return sqrt(squaredDistance(point));
    }

    static if (N == 2u)
    Box intersect(ref const(Box) o) pure const nothrow
    {
        assert(isSorted());
        assert(o.isSorted());
        auto xmin = .max(min.x, o.min.x);
        auto ymin = .max(min.y, o.min.y);
        auto xmax = .min(max.x, o.max.x);
        auto ymax = .min(max.y, o.max.y);
        return Box(xmin, ymin, xmax, ymax);
    }


    /// Extends the area of this Box.
    Box grow(Bound space) pure const nothrow
    {
        Box res = this;
        res.min -= space;
        res.max += space;
        return res;
    }

    /// Shrink the area of this Box.
    Box shrink(Bound space) pure const nothrow
    {
        return grow(-space);
    }

    /// Extends the area of this Box.
    Box grow(T space) pure const nothrow
    {
        return grow(Bound(space));
    }

    /// Shrink the area of this Box.
    Box shrink(T space) pure const nothrow
    {
        return shrink(Bound(space));
    }

    /// Assign with another box.
    ref Box opAssign(U)(U x) nothrow if (is(typeof(x.isBox)))
    {
        static if(is(U.element_t : T))
        {
            static if(U._size == _size)
            {
                min = x.min;
                max = x.max;
            }
            else
            {
                static assert(false, "no conversion between boxes with different dimensions");
            }
        }
        else
        {
            static assert(false, Format!("no conversion from %s to %s", U.element_t.stringof, element_t.stringof));
        }
        return this;
    }

    /// Returns: true if comparing equal boxes.
    bool opEquals(U)(U other) pure const nothrow if (is(U : Box))
    {
        return (min == other.min) && (max == other.max);
    }

    /// Comparison with another Box (for sorting).
    int opCmp(ref const Box rhs) @safe pure nothrow const @nogc
    {
        const cmpMin = min.opCmp(rhs.min);
        if(cmpMin != 0) { return cmpMin; }
        return max.opCmp(rhs.max);
    }

private:
    enum isBox = true;
    enum _size = N;
    alias T element_t;

    /// Returns: true if each dimension of the box is >= 0.
    bool isSorted() pure const nothrow
    {
        foreach(i; 0 .. N) if(min.vector[i] > max.vector[i])
        {
            return false;
        }
        return true;
    }
}

alias box2i = Box!(int, 2);
alias box3i = Box!(int, 3);
alias box2  = Box!(float, 2);
alias box3  = Box!(float, 3);
alias box2d = Box!(double, 2);
alias box3d = Box!(double, 3);
unittest
{
    box2i a = box2i(1, 2, 3, 4);
    assert(a.width == 2);
    assert(a.height == 2);
    assert(a.volume == 4);
    box2i b = box2i(vec2i(1, 2), vec2i(3, 4));
    assert(a == b);
    box2i c = box2i(0, 0, 1,1);
    assert(c.contains(vec2i(0, 0)));
    assert(!c.contains(vec2i(1, 1)));
    assert(b.contains(b));
}
