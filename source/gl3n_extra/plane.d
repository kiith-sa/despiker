//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module gl3n_extra.plane;


public import gl3n.plane;


@safe pure nothrow @nogc:

/** Construct a plane from a point on the plane and normal of the plane.
 *
 * Params:
 *
 * point  = A point anywhere on the plane.
 * normal = Normal of the plane.
 * 
 */
PlaneT!F planeFromPointNormal(F)(const Vector!(F, 3) point, const Vector!(F, 3) normal)
{
    return PlaneT!F(normal, -dot(point, normal));
}

/** Find the intersection between a plane and a line, if any.
 *
 * Params:
 *
 * plane        = Plane to check for intersection with.
 * lineOrigin   = Origin of the line (the 'anchor point' fom which lineVector starts)
 * lineVector   = Vector (direction) of the line.
 * intersection = If the plane intersects the line, the intersection point is written here.
 *
 * Returns: true if the plane intersects the line. false otherwise.
 * 
 */
bool intersectsLine(F)(const PlaneT!F plane, const Vector!(F, 3) lineOrigin,
                       const Vector!(F, 3) lineVector, out Vector!(F, 3) intersection)
{
    const t2 = dot(plane.normal, lineVector);
    if(t2 == 0.0f) { return false; }

    const t = -(dot(plane.normal, lineOrigin) + plane.d) / t2;
    intersection = lineOrigin + lineVector * t;
    return true;
}
