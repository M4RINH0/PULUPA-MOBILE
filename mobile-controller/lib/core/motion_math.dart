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

// Active change of basis to X right, Y up, -Z forward (Godot convention).
final deviceWorldToGame = Rotation.axisAngle(const Vec3(1, 0, 0), -math.pi / 2);

Vec3 vectorInGameAxes(Vec3 value) => Vec3(value.x, value.z, -value.y);

Rotation rotationInGameAxes(Rotation value) =>
    (deviceWorldToGame * value * deviceWorldToGame.inverseUnit).normalized();
