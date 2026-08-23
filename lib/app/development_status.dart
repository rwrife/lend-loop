/// Immutable copy displayed while the first Lend Loop workflow is built.
final class DevelopmentStatus {
  const DevelopmentStatus({
    required this.productName,
    required this.headline,
    required this.detail,
  });

  static const DevelopmentStatus current = DevelopmentStatus(
    productName: 'Lend Loop',
    headline: 'Under development',
    detail: 'Private, offline lending records are coming soon.',
  );

  final String productName;
  final String headline;
  final String detail;
}
