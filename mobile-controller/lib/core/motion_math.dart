import 'dart:math' as math;

class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const zero = Vec3(0, 0, 0);
  static const up = Vec3(0, 0, 1);

  final double x;
  final double y;
  final double z;

  double get length => math.sqrt(dot(this));
  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;

  Vec3 operator +(Vec3 rhs) => Vec3(x + rhs.x, y + rhs.y, z + rhs.z);
  Vec3 operator -(Vec3 rhs) => Vec3(x - rhs.x, y - rhs.y, z - rhs.z);
  Vec3 operator *(double scale) => Vec3(x * scale, y * scale, z * scale);
  double dot(Vec3 rhs) => x * rhs.x + y * rhs.y + z * rhs.z;
  Vec3 cross(Vec3 rhs) =>
      Vec3(y * rhs.z - z * rhs.y, z * rhs.x - x * rhs.z, x * rhs.y - y * rhs.x);
  Vec3 normalized() {
    final magnitude = length;
    return magnitude > 0 ? this * (1 / magnitude) : zero;
  }
}

class Rotation {
  const Rotation(this.x, this.y, this.z, this.w);

  static const identity = Rotation(0, 0, 0, 1);

  final double x;
  final double y;
  final double z;
  final double w;

  double dot(Rotation rhs) => x * rhs.x + y * rhs.y + z * rhs.z + w * rhs.w;
  bool get isUsable => dot(this).isFinite && dot(this) > 1e-12;

  Rotation normalized() {
    final scale = 1 / math.sqrt(dot(this));
    return Rotation(x * scale, y * scale, z * scale, w * scale);
  }

  Rotation get inverseUnit => Rotation(-x, -y, -z, w);

  // Hamilton product. When rotating a vector, the right operand acts first.
  Rotation operator *(Rotation rhs) => Rotation(
    w * rhs.x + x * rhs.w + y * rhs.z - z * rhs.y,
    w * rhs.y - x * rhs.z + y * rhs.w + z * rhs.x,
    w * rhs.z + x * rhs.y - y * rhs.x + z * rhs.w,
    w * rhs.w - x * rhs.x - y * rhs.y - z * rhs.z,
  );

  Vec3 rotate(Vec3 vector) {
    final imaginary = Vec3(x, y, z);
    final twiceCross = imaginary.cross(vector) * 2;
    return vector + twiceCross * w + imaginary.cross(twiceCross);
  }

  factory Rotation.axisAngle(Vec3 axis, double radians) {
    if (axis.length == 0) return identity;
    final v = axis.normalized() * math.sin(radians / 2);
    return Rotation(v.x, v.y, v.z, math.cos(radians / 2));
  }

  factory Rotation.between(Vec3 from, Vec3 to) {
    final a = from.normalized();
    final b = to.normalized();
    final cosine = a.dot(b);
    if (cosine < -0.999999) {
      final perpendicular = a.cross(
        a.x.abs() < 0.9 ? const Vec3(1, 0, 0) : Vec3.up,
      );
      return Rotation.axisAngle(perpendicular, math.pi);
    }
    final axis = a.cross(b);
    return Rotation(axis.x, axis.y, axis.z, 1 + cosine).normalized();
  }

  double angleTo(Rotation target) =>
      2 * math.acos(dot(target).abs().clamp(0.0, 1.0));

  Rotation slerp(Rotation target, double amount) {
    final cosine = dot(target);
    final sign = cosine < 0 ? -1.0 : 1.0;
    final distance = cosine.abs().clamp(0.0, 1.0);
    final angle = math.acos(distance);
    final sinAngle = math.sin(angle);
    final a = distance > 0.9995
        ? 1 - amount
        : math.sin((1 - amount) * angle) / sinAngle;
    final b = distance > 0.9995
        ? amount * sign
        : math.sin(amount * angle) / sinAngle * sign;
    return Rotation(
      x * a + target.x * b,
      y * a + target.y * b,
      z * a + target.z * b,
      w * a + target.w * b,
    ).normalized();
  }

  // Z-Y-X Euler decomposition, for diagnostics only.
  ({double pitch, double roll, double yaw}) get eulerDegrees {
    const degrees = 180 / math.pi;
    return (
      roll: math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * degrees,
      pitch: math.asin((2 * (w * y - z * x)).clamp(-1.0, 1.0)) * degrees,
      yaw: math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * degrees,
    );
  }
}

// Active change of basis to the wire game axes: right-handed, X right, Y up,
// -Z forward. Unity (left-handed, +Z forward) converts on its side; see
// protocol/unity/README.md.
final deviceWorldToGame = Rotation.axisAngle(const Vec3(1, 0, 0), -math.pi / 2);

Vec3 vectorInGameAxes(Vec3 value) => Vec3(value.x, value.z, -value.y);

Rotation rotationInGameAxes(Rotation value) =>
    (deviceWorldToGame * value * deviceWorldToGame.inverseUnit).normalized();

// Heading of a device-to-world pose: the yaw about world up (+Z) that takes
// world +Y to the horizontal direction the player faces.
//
// Whenever the screen is tilted toward the player (upright, reclined, in
// portrait or held sideways in landscape) the player looks into the screen,
// so the facing direction is the back of the phone: -screen normal projected
// on the floor. Only when the phone lies almost flat (screen within 30° of
// straight up or down) does that projection vanish; then the device top,
// which is the top of the portrait-locked UI, is the best guess.
Rotation headingOf(Rotation pose) {
  final screen = pose.rotate(Vec3.up);
  var forward = Vec3(-screen.x, -screen.y, 0);
  if (forward.length < 0.5) {
    final top = pose.rotate(const Vec3(0, 1, 0));
    final flatSign = screen.z < 0 ? -1.0 : 1.0;
    forward = Vec3(top.x, top.y, 0) * flatSign;
    if (forward.length < 0.2) {
      final right = pose.rotate(const Vec3(1, 0, 0));
      forward = Vec3.up.cross(Vec3(right.x, right.y, 0));
    }
  }
  if (forward.length < 1e-9) return Rotation.identity;
  return Rotation.between(const Vec3(0, 1, 0), forward);
}

// Device-to-game pose as the player sees the phone: the heading is removed,
// so game -Z is where the player faces, +Y is up and +Z points back at the
// player. A phone held upright in portrait with the screen toward the player
// maps to identity; held sideways it shows sideways.
Rotation poseInGameAxes(Rotation pose, Rotation heading) =>
    (deviceWorldToGame * heading.inverseUnit * pose).normalized();

// Intuitive angles of a rotation expressed in game axes (X right, Y up,
// +Z toward the player), decomposed yaw–pitch–roll (Y, then X, then Z):
//   forward: tilting the top away from the player is positive;
//   roll:    lowering the right side is positive;
//   yaw:     turning to the right is positive.
({double forward, double roll, double yaw}) gameAnglesDegrees(Rotation g) {
  const degrees = 180 / math.pi;
  final x = g.x, y = g.y, z = g.z, w = g.w;
  final m23 = 2 * (y * z - w * x);
  final pitch = math.asin((-m23).clamp(-1.0, 1.0));
  double yaw;
  double roll;
  if (m23.abs() < 0.9999) {
    yaw = math.atan2(2 * (x * z + w * y), 1 - 2 * (x * x + y * y));
    roll = math.atan2(2 * (x * y + w * z), 1 - 2 * (x * x + z * z));
  } else {
    yaw = math.atan2(-2 * (x * z - w * y), 1 - 2 * (y * y + z * z));
    roll = 0;
  }
  return (forward: -pitch * degrees, roll: -roll * degrees, yaw: -yaw * degrees);
}

// Rotation from the neutral pose to the current pose, expressed in a
// gravity-aligned frame that follows the neutral heading: +Z stays world up
// and +Y is the facing direction. Equals identity at the neutral pose for any
// holding posture. For a flat, screen-up neutral pose this reduces to
// inverse(reference) * current.
Rotation gravityAlignedRelative(Rotation reference, Rotation current) {
  final heading = headingOf(reference);
  return (heading.inverseUnit * current * reference.inverseUnit * heading)
      .normalized();
}
