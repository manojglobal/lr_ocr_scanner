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
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(steps.length * 2 - 1, (index) {
              if (index.isOdd) {
                final priorStep = (index ~/ 2) + 1;
                final isPassed = priorStep < activeStep;
                return Container(
                  width: 24,
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
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
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: circleBg,
                          shape: BoxShape.circle,
                          border: circleBorder,
                        ),
                        child: Center(
                          child: isCompleted
                              ? const Icon(Icons.check, size: 14, color: Colors.white)
                              : Text(
                                  '$stepNum',
                                  style: TextStyle(
                                    color: circleText,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        stepName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                          color: isActive
                              ? brandBlue
                              : (isCompleted ? const Color(0xFF334155) : const Color(0xFF94A3B8)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
