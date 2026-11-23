import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/motion_math.dart';
import '../../core/theme/pulupa_theme.dart';

class PhoneModel extends StatelessWidget {
  const PhoneModel({super.key, required this.rotation, this.height = 242});

  final ValueNotifier<Rotation> rotation;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Modelo do celular acompanhando a orientação',
    child: RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: CustomPaint(painter: _StagePainter(rotation)),
        ),
      ),
    ),
  );
}

class _StagePainter extends CustomPainter {
  _StagePainter(this.rotation) : super(repaint: rotation);

  final ValueNotifier<Rotation> rotation;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(PulupaColors.navy, BlendMode.src);
    final center = size.center(Offset.zero);
    final sizeUnit = math.min(size.width, size.height);
    final grid = Paint()..color = const Color(0xFF354364);
    for (var x = center.dx % 18; x < size.width; x += 18) {
      for (var y = center.dy % 18; y < size.height; y += 18) {
        canvas.drawCircle(Offset(x, y), 0.85, grid);
      }
    }
    grid.style = PaintingStyle.stroke;
    canvas.drawCircle(center, sizeUnit * 0.38, grid);
    canvas.drawCircle(center, sizeUnit * 0.46, grid);
    final accent = Paint()
      ..color = PulupaColors.yellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final orbit = Rect.fromCircle(center: center, radius: sizeUnit * 0.46);
    canvas.drawArc(orbit, 0.25, 0.23, false, accent);
    canvas.drawArc(
      orbit,
      math.pi + 0.25,
      0.23,
      false,
      accent..color = PulupaColors.pink,
    );
    paintPhone(canvas, center, sizeUnit * 0.29, rotation.value);
  }

  @override
  bool shouldRepaint(covariant _StagePainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}

final _cameraTilt =
    Rotation.axisAngle(const Vec3(1, 0, 0), -0.22) *
    Rotation.axisAngle(const Vec3(0, 1, 0), 0.38);

// A convex solid with orthogonal local axes and a fixed perspective camera.
void paintPhone(
  Canvas canvas,
  Offset center,
  double scale,
  Rotation orientation,
) {
  final pose = _cameraTilt * orientation;
  const camera = Vec3(0, 0, 7);
  final paint = Paint()..isAntiAlias = true;

  Offset project(Vec3 model) {
    final depth = scale * camera.z / (camera.z - model.z);
    return center + Offset(model.x * depth, -model.y * depth);
  }

  List<Vec3> bevel(double w, double h, double r, double z) => [
    Vec3(-w, -h + r, z),
    Vec3(-w + r, -h, z),
    Vec3(w - r, -h, z),
    Vec3(w, -h + r, z),
    Vec3(w, h - r, z),
    Vec3(w - r, h, z),
    Vec3(-w + r, h, z),
    Vec3(-w, h - r, z),
  ];

  void polygon(List<Vec3> points, Color color) {
    final path = Path()..addPolygon(points.map(project).toList(), true);
    canvas.drawPath(path, paint..color = color);
  }

  bool facing(List<Vec3> points) {
    final origin = points.first;
    final normal = (points[1] - origin).cross(points[2] - origin);
    return normal.dot(camera - origin) > 0;
  }

  void surface(List<Vec3> shape, Color color) =>
      polygon(shape.map(pose.rotate).toList(), color);
  final front = bevel(0.65, 1.18, 0.13, 0.13).map(pose.rotate).toList();
  final back = bevel(0.65, 1.18, 0.13, -0.13).map(pose.rotate).toList();

  for (var i = 0; i < front.length; i++) {
    final next = (i + 1) % front.length;
    final face = [front[i], back[i], back[next], front[next]];
    if (facing(face)) {
      polygon(
        face,
        i.isEven ? const Color(0xFFB7891D) : const Color(0xFFEDAD20),
      );
    }
  }
  if (facing(back.reversed.toList())) {
    polygon(back, PulupaColors.yellow);
    surface(
      bevel(
        0.18,
        0.22,
        0.06,
        -0.132,
      ).map((v) => v + const Vec3(-0.29, 0.78, 0)).toList(),
      PulupaColors.navy,
    );
    return;
  }
  if (!facing(front)) return;
  polygon(front, PulupaColors.yellow);
  surface(bevel(0.57, 1.09, 0.095, 0.131), PulupaColors.navy);
  surface(bevel(0.49, 0.91, 0.07, 0.132), PulupaColors.blue);
  // Front display details live in the same plane as the phone.
  surface(const [
    Vec3(-0.42, -0.78, 0.133),
    Vec3(0.37, 0.72, 0.133),
    Vec3(0.42, 0.40, 0.133),
    Vec3(-0.10, -0.78, 0.133),
  ], const Color(0xFF7289FF));
  surface(const [
    Vec3(-0.29, -0.30, 0.133),
    Vec3(-0.01, 0.32, 0.133),
    Vec3(0.29, 0.32, 0.133),
    Vec3(0.01, -0.30, 0.133),
  ], PulupaColors.pink);
  surface(const [
    Vec3(-0.14, 0.93, 0.134),
    Vec3(0.14, 0.93, 0.134),
    Vec3(0.14, 0.96, 0.134),
    Vec3(-0.14, 0.96, 0.134),
  ], const Color(0xFFC6CBE4));
  surface(const [
    Vec3(-0.15, -0.83, 0.134),
    Vec3(0.15, -0.83, 0.134),
    Vec3(0.15, -0.80, 0.134),
    Vec3(-0.15, -0.80, 0.134),
  ], Colors.white);
}
