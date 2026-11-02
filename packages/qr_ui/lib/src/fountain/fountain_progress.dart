/// Fountain progress metadata emitted during continuous reassembly.
class FountainProgress {
  final int totalFragments;
  final int resolvedFragments;
  final int currentSeqNum;
  final bool isComplete;

  const FountainProgress({
    required this.totalFragments,
    required this.resolvedFragments,
    required this.currentSeqNum,
    required this.isComplete,
  });

  const FountainProgress.initial()
      : totalFragments = 0,
        resolvedFragments = 0,
        currentSeqNum = 0,
        isComplete = false;

  double get percentage =>
      totalFragments > 0 ? (resolvedFragments / totalFragments).clamp(0.0, 1.0) : 0.0;
}
