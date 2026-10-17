import 'dart:math';
import 'package:flutter_test/flutter_test.dart';

/// Scientific benchmark harness to evaluate Character Error Rate (CER),
/// Word Error Rate (WER), and Field-Level Accuracy.
class AccuracyMetrics {
  /// Computes Character Error Rate (CER) = (Insertions + Deletions + Substitutions) / Reference Length
  static double calculateCER(String hypothesis, String reference) {
    if (reference.isEmpty) return hypothesis.isEmpty ? 0.0 : 1.0;
    final dist = _levenshteinDistance(hypothesis.split(''), reference.split(''));
    return dist / reference.length;
  }

  /// Computes Word Error Rate (WER) = Word Levenshtein Distance / Reference Word Count
  static double calculateWER(String hypothesis, String reference) {
    final hypWords = hypothesis.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final refWords = reference.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (refWords.isEmpty) return hypWords.isEmpty ? 0.0 : 1.0;
    final dist = _levenshteinDistance(hypWords, refWords);
    return dist / refWords.length;
  }

  /// Computes Field-Level Accuracy = (Matching Fields) / (Total Expected Ground Truth Fields)
  static double calculateFieldAccuracy(Map<String, String> hypothesis, Map<String, String> groundTruth) {
    if (groundTruth.isEmpty) return 1.0;
    int matches = 0;
    for (final entry in groundTruth.entries) {
      final hypVal = hypothesis[entry.key]?.trim().toLowerCase();
      final refVal = entry.value.trim().toLowerCase();
      if (hypVal != null && hypVal == refVal) {
        matches++;
      }
    }
    return matches / groundTruth.length;
  }

  static int _levenshteinDistance<T>(List<T> a, List<T> b) {
    final d = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
    for (int i = 0; i <= a.length; i++) d[i][0] = i;
    for (int j = 0; j <= b.length; j++) d[0][j] = j;

    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        final cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
        d[i][j] = [
          d[i - 1][j] + 1,      // deletion
          d[i][j - 1] + 1,      // insertion
          d[i - 1][j - 1] + cost // substitution
        ].reduce(min);
      }
    }
    return d[a.length][b.length];
  }
}

void main() {
  group('AccuracyMetrics - CER, WER, and Field Accuracy Benchmark', () {
    test('calculates CER accurately on known substitutions', () {
      const reference = 'ROHIT AGARWAL';
      const hypothesis = 'ROHIT AGRWAL'; // 1 deletion ('A')
      final cer = AccuracyMetrics.calculateCER(hypothesis, reference);
      expect(cer, closeTo(1 / reference.length, 0.01));
    });

    test('calculates WER accurately on missing or substituted words', () {
      const reference = 'State of Uttar Pradesh';
      const hypothesis = 'State of Uttar'; // 1 missing word
      final wer = AccuracyMetrics.calculateWER(hypothesis, reference);
      expect(wer, closeTo(1 / 4, 0.01));
    });

    test('calculates Field Accuracy on key-value extractions', () {
      final groundTruth = {
        'Name': 'Rohit Agarwal',
        'Relationship': 'Father',
        'EPIC No.': 'ABEFG123',
        'State': 'Uttar Pradesh',
      };

      final hypothesis = {
        'Name': 'Rohit Agarwal',
        'Relationship': 'Father',
        'EPIC No.': 'ABEFG123',
        'State': 'Delhi', // 1 mismatched field
      };

      final accuracy = AccuracyMetrics.calculateFieldAccuracy(hypothesis, groundTruth);
      expect(accuracy, 0.75); // 3 out of 4 matches = 75%
    });
  });
}
