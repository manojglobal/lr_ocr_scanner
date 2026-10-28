import 'package:flutter/material.dart';
import '../../state/batch_controller.dart';
import '../home_screen.dart';
import '../screens/batch_queue_screen.dart';
import '../screens/edit_bilty_screen.dart';

/// Global 3-Step Process Flow Bar (Consistent Footer Indicator):
/// Step 1: Upload LR
/// Step 2: LR & Master Verification
/// Step 3: LR List
class StepIndicatorBar extends StatelessWidget {
  final int currentStep; // 1, 2, or 3
  final BatchProcessingController? controller;

  const StepIndicatorBar({
    super.key,
    required this.currentStep,
    this.controller,
  });

  static const List<Map<String, dynamic>> steps = [
    {'step': 1, 'name': 'Upload LR', 'screen': 'upload'},
    {'step': 2, 'name': 'LR & Master Verification', 'screen': 'verify'},
    {'step': 3, 'name': 'LR List', 'screen': 'lr_list'},
  ];

  int get normalizedStep {
    if (currentStep == 1) return 1;
    if (currentStep == 2) return 2;
    if (currentStep == 3) return 3;
    // Map legacy screen numbers matching Web screenMap:
    // Screen 1-3 -> Step 1 (Upload LR)
    // Screen 4-6 -> Step 2 (LR & Master Verification)
    // Screen 7-10 -> Step 3 (LR List & Excel Preview)
    if (currentStep >= 4 && currentStep <= 6) return 2;
    if (currentStep >= 7) return 3;
    return currentStep.clamp(1, 3);
  }

  void _handleStepTap(BuildContext context, int step) {
    if (step == normalizedStep) return;

    final ctrl = controller;
    if (ctrl == null) return;

    switch (step) {
      case 1:
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => HomeScreen(controller: ctrl)),
          (route) => false,
        );
        break;
      case 2:
        if (ctrl.items.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => EditBiltyScreen(item: ctrl.items.first, controller: ctrl, initialTab: 0),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No consignment note in batch to verify. Upload an LR first.')),
          );
        }
        break;
      case 3:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BatchQueueScreen(controller: ctrl),
          ),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    const brandBlue = Color(0xFF0284C7);
    const brandGreen = Color(0xFF16A34A);
    const borderSlate = Color(0xFFE2E8F0);
    final activeStep = normalizedStep;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: borderSlate, width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            offset: const Offset(0, -1),
            blurRadius: 4,
          ),
        ],
      ),
      padding: const EdgeInsets.only(top: 6, bottom: 4, left: 6, right: 6),
      child: SafeArea(
        top: false,
        left: true,
        right: true,
        bottom: true,
        minimum: const EdgeInsets.only(bottom: 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isSmall = constraints.maxWidth < 360;
            final isMedium = constraints.maxWidth < 420;
            final circleSize = isSmall ? 18.0 : (isMedium ? 20.0 : 22.0);
            final fontSize = isSmall ? 9.5 : (isMedium ? 10.5 : 11.5);
            final dividerWidth = isSmall ? 8.0 : (isMedium ? 14.0 : 18.0);
            final hPadding = isSmall ? 1.0 : 3.0;

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth - 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(steps.length * 2 - 1, (index) {
                    if (index.isOdd) {
                      final priorStep = (index ~/ 2) + 1;
                      final isPassed = priorStep < activeStep;
                      return Container(
                        width: dividerWidth,
                        height: 2,
                        margin: EdgeInsets.symmetric(horizontal: hPadding),
                        color: isPassed ? brandGreen : const Color(0xFFE2E8F0),
                      );
                    }

                    final stepIndex = index ~/ 2;
                    final stepData = steps[stepIndex];
                    final int stepNum = stepData['step'] as int;
                    final String stepName = stepData['name'] as String;

                    final bool isCompleted = stepNum < activeStep;
                    final bool isActive = stepNum == activeStep;

                    Color circleBg;
                    Color circleText;
                    Border? circleBorder;

                    if (isActive) {
                      circleBg = brandBlue;
                      circleText = Colors.white;
                      circleBorder = Border.all(color: const Color(0xFFBAE6FD), width: 2);
                    } else if (isCompleted) {
                      circleBg = brandGreen;
                      circleText = Colors.white;
                    } else {
                      circleBg = const Color(0xFFF1F5F9);
                      circleText = const Color(0xFF64748B);
                    }

                    return InkWell(
                      onTap: controller != null ? () => _handleStepTap(context, stepNum) : null,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: hPadding, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: circleSize,
                              height: circleSize,
                              decoration: BoxDecoration(
                                color: circleBg,
                                shape: BoxShape.circle,
                                border: circleBorder,
                              ),
                              child: Center(
                                child: isCompleted
                                    ? Icon(Icons.check, size: circleSize * 0.58, color: Colors.white)
                                    : Text(
                                        '$stepNum',
                                        style: TextStyle(
                                          color: circleText,
                                          fontSize: circleSize * 0.46,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                stepName,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: fontSize,
                                  fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                                  color: isActive
                                      ? brandBlue
                                      : (isCompleted ? const Color(0xFF334155) : const Color(0xFF94A3B8)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
