import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:starshare/screens/qr_generator_screen.dart';
import 'package:starshare/screens/qr_scanner_screen.dart';
import 'send_file_screen.dart';
import 'receive_file_screen.dart';
import 'history_screen.dart';
import '../services/database_service.dart';
import '../utils/input_validator.dart';

/// Colors used on this screen. Move these into your app's ThemeData
/// when you restyle the other screens.
class _Palette {
  static const background = Color(0xFF0B1017);
  static const surface = Color(0xFF121A24);
  static const border = Color(0xFF1E2A38);
  static const text = Color(0xFFEEF2F7);
  static const muted = Color(0xFF8B98A9);
  static const accent = Color(0xFF2563EB);
  static const accentLight = Color(0xFF60A5FA);
  static const accentTint = Color(0x292563EB); // accent at about 16%
  static const onAccentMuted = Color(0xFFDBE7FF);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _sentCount = 0;
  int _receivedCount = 0;
  List<_Transfer> _recent = const [];
  String? _localIp;
  bool _loading = true;
  String _query = '';

  final TextEditingController _searchController = TextEditingController();
  final InputValidator _validator = const InputValidator();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- data

  Future<void> _load() async {
    try {
      final db = await DatabaseService.database;

      // One query for both counts instead of two.
      final counts = await db.rawQuery(
        'SELECT direction, COUNT(*) AS count FROM transfers GROUP BY direction',
      );
      final rows = await db.rawQuery(
        'SELECT * FROM transfers ORDER BY rowid DESC LIMIT 50',
      );
      final ip = await _findLocalIp();

      var sent = 0;
      var received = 0;
      for (final row in counts) {
        final count = (row['count'] as int?) ?? 0;
        if (row['direction'] == 'Sent') sent = count;
        if (row['direction'] == 'Received') received = count;
      }

      if (!mounted) return;
      setState(() {
        _sentCount = sent;
        _receivedCount = received;
        _recent = rows.map(_Transfer.fromRow).toList();
        _localIp = ip;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('Could not load your transfers.');
    }
  }

  /// First non-loopback IPv4 address, or null when the phone is offline.
  Future<String?> _findLocalIp() async {
    try {
      final networkInterfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final networkInterface in networkInterfaces) {
        if (networkInterface.addresses.isNotEmpty) {
          return networkInterface.addresses.first.address;
        }
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------- actions

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _Palette.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _Palette.border),
          ),
        ),
      );
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
    if (mounted) _load();
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );

    if (!mounted || result == null) return;

    // Treat the scanned data as untrusted input.
    if (result is! Map) {
      HapticFeedback.heavyImpact();
      _showMessage('This QR code is not a valid StarShare code.');
      return;
    }

    final rawIp = result['ip'];
    final port = result['port'];
    final String? ip = rawIp is String ? rawIp : null;
    final portNumber = int.tryParse('$port');

    if (ip == null ||
        InternetAddress.tryParse(ip) == null ||
        portNumber == null ||
        portNumber < 1 ||
        portNumber > 65535) {
      HapticFeedback.heavyImpact();
      _showMessage('This QR code is not a valid StarShare code.');
      return;
    }

    // TODO: hand `ip` and `port` to your send flow once it accepts them
    // (for example through a constructor parameter).
    HapticFeedback.mediumImpact();
    _showMessage('QR code scanned: $ip:$port');
  }

  void _submitSearch() {
    FocusScope.of(context).unfocus();
    final error = _validator.validateSearch(_searchController.text);
    if (error != null) {
      _showMessage(error);
      return;
    }
    setState(() => _query = _searchController.text.trim());
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  List<_Transfer> get _visibleTransfers {
    if (_query.isEmpty) return _recent.take(4).toList();
    final q = _query.toLowerCase();
    return _recent
        .where((t) => t.name.toLowerCase().contains(q))
        .take(10)
        .toList();
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).copyWith(
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: _Palette.accent,
        onPrimary: Colors.white,
        secondaryContainer: _Palette.accentTint,
        onSecondaryContainer: _Palette.accentLight,
        surface: _Palette.surface,
        onSurface: _Palette.text,
        onSurfaceVariant: _Palette.muted,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: _Palette.background,
        surfaceTintColor: Colors.transparent,
        indicatorColor: _Palette.accentTint,
      ),
    );

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: _Palette.background,
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            color: _Palette.accentLight,
            backgroundColor: _Palette.surface,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                _Reveal(index: 0, child: _buildHeader()),
                const SizedBox(height: 20),
                _Reveal(index: 1, child: _buildSearchField()),
                const SizedBox(height: 16),
                _Reveal(index: 2, child: _buildQuickActions()),
                const SizedBox(height: 16),
                _Reveal(index: 3, child: _buildStatsCard()),
                const SizedBox(height: 16),
                _Reveal(index: 4, child: _buildRecentTransfers()),
              ],
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (index) {
            HapticFeedback.selectionClick();
            // History opens on top of Home, so Home stays selected.
            if (index == 1) _open(const HistoryScreen());
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_rounded),
              label: 'History',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final online = _localIp != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _Palette.accent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.star_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'StarShare',
              style: TextStyle(
                color: _Palette.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Notifications',
              style: IconButton.styleFrom(
                backgroundColor: _Palette.surface,
                foregroundColor: _Palette.text,
                minimumSize: const Size(48, 48),
                side: const BorderSide(color: _Palette.border),
              ),
              icon: const Icon(Icons.notifications_none_rounded),
              // TODO: open a notifications screen once you have one.
              onPressed: () {
                HapticFeedback.selectionClick();
                _showMessage('No new notifications');
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        Semantics(
          header: true,
          child: Text(
            _greeting,
            style: const TextStyle(
              color: _Palette.text,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: online ? _Palette.accentLight : _Palette.muted,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                online
                    ? 'Ready to receive · $_localIp'
                    : 'No network connection',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _Palette.muted, fontSize: 14),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color),
    );

    return TextField(
      controller: _searchController,
      style: const TextStyle(color: _Palette.text),
      cursorColor: _Palette.accentLight,
      textInputAction: TextInputAction.search,
      onChanged: (value) => setState(() => _query = value.trim()),
      onSubmitted: (_) => _submitSearch(),
      decoration: InputDecoration(
        hintText: 'Search transfers',
        hintStyle: const TextStyle(color: _Palette.muted),
        filled: true,
        fillColor: _Palette.surface,
        prefixIcon: const Icon(Icons.search_rounded, color: _Palette.muted),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
          tooltip: 'Clear search',
          icon: const Icon(Icons.close_rounded, color: _Palette.muted),
          onPressed: _clearSearch,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        enabledBorder: border(_Palette.border),
        focusedBorder: border(_Palette.accentLight),
        border: border(_Palette.border),
      ),
    );
  }

  Widget _buildQuickActions() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                icon: Icons.upload_file_rounded,
                label: 'Send',
                subtitle: 'Pick files',
                filled: true,
                onTap: () => _open(const SendFileScreen()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionTile(
                icon: Icons.download_rounded,
                label: 'Receive',
                subtitle: 'Wait for sender',
                onTap: () => _open(const ReceiveFileScreen()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                icon: Icons.qr_code_scanner_rounded,
                label: 'Scan',
                subtitle: 'Join a device',
                onTap: _scan,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionTile(
                icon: Icons.qr_code_rounded,
                label: 'Generate',
                subtitle: 'Show your code',
                onTap: () => _open(const QrGeneratorScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatsCard() {
    return Container(
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _Palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _StatTile(
              icon: Icons.north_east_rounded,
              value: _loading ? null : _sentCount,
              label: 'Files sent',
            ),
          ),
          Container(width: 1, height: 72, color: _Palette.border),
          Expanded(
            child: _StatTile(
              icon: Icons.south_west_rounded,
              value: _loading ? null : _receivedCount,
              label: 'Files received',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTransfers() {
    final transfers = _visibleTransfers;
    final searching = _query.isNotEmpty;

    final Widget content;
    if (_loading) {
      content = const Column(
        children: [
          _SkeletonRow(),
          Divider(height: 1, color: _Palette.border),
          _SkeletonRow(),
          Divider(height: 1, color: _Palette.border),
          _SkeletonRow(),
        ],
      );
    } else if (transfers.isEmpty) {
      content = _buildEmptyState(searching);
    } else {
      content = Column(
        children: [
          for (var i = 0; i < transfers.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: _Palette.border),
            _TransferRow(transfer: transfers[i]),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              searching ? 'Results' : 'Recent transfers',
              style: const TextStyle(
                color: _Palette.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextButton(
              onPressed: () => _open(const HistoryScreen()),
              style: TextButton.styleFrom(
                foregroundColor: _Palette.accentLight,
                minimumSize: const Size(48, 48),
              ),
              child: const Text('See all'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: _Palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _Palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: content,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(bool searching) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            Icon(
              searching ? Icons.search_off_rounded : Icons.swap_horiz_rounded,
              color: _Palette.muted,
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              searching ? 'No matching transfers' : 'No transfers yet',
              style: const TextStyle(
                color: _Palette.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              searching
                  ? 'Try a different file name.'
                  : 'Send or receive a file and it will show up here.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _Palette.muted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- widgets

/// Fades and slides a section in once, with a small stagger by [index].
class _Reveal extends StatefulWidget {
  const _Reveal({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    Future.delayed(Duration(milliseconds: 70 * widget.index), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the system "reduce motion" setting.
    if (MediaQuery.of(context).disableAnimations) return widget.child;

    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final iconBackground =
    filled ? const Color(0x33FFFFFF) : _Palette.accentTint;
    final iconColor = filled ? Colors.white : _Palette.accentLight;

    return Semantics(
      button: true,
      label: '$label. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: filled ? _Palette.accent : _Palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: filled
              ? BorderSide.none
              : const BorderSide(color: _Palette.border),
        ),
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 76,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconBackground,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: iconColor, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: filled ? Colors.white : _Palette.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: filled
                                ? _Palette.onAccentMuted
                                : _Palette.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;

  /// null while loading.
  final int? value;
  final String label;

  @override
  Widget build(BuildContext context) {
    const valueStyle = TextStyle(
      color: _Palette.text,
      fontSize: 20,
      fontWeight: FontWeight.w700,
    );
    final count = value;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          _IconBox(icon: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (count == null)
                  const Text('–', style: valueStyle)
                else
                  TweenAnimationBuilder<int>(
                    tween: IntTween(begin: 0, end: count),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    builder: (context, current, child) =>
                        Text('$current', style: valueStyle),
                  ),
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _Palette.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.transfer});

  final _Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final meta = [
      transfer.sent ? 'Sent' : 'Received',
      if (transfer.size != null) transfer.size!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _IconBox(
            icon: transfer.sent
                ? Icons.north_east_rounded
                : Icons.south_west_rounded,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transfer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _Palette.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  style: const TextStyle(color: _Palette.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          if (transfer.when != null) ...[
            const SizedBox(width: 12),
            Text(
              transfer.when!,
              style: const TextStyle(color: _Palette.muted, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

/// Placeholder row shown while transfers load.
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  Widget _bar(double width, double height) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _Palette.border,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _Palette.border,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bar(140, 12),
              const SizedBox(height: 8),
              _bar(90, 10),
            ],
          ),
        ],
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _Palette.accentTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: _Palette.accentLight, size: 20),
    );
  }
}

// ------------------------------------------------------------------ model

class _Transfer {
  const _Transfer({
    required this.name,
    required this.sent,
    this.size,
    this.when,
  });

  final String name;
  final bool sent;
  final String? size;
  final String? when;

  /// Reads one row of the `transfers` table.
  ///
  /// ASSUMPTION: I only know the `direction` column from your code. The
  /// other column names below are guesses, so change the lists to match
  /// your real schema.
  factory _Transfer.fromRow(Map<String, Object?> row) {
    Object? pick(List<String> keys) {
      for (final key in keys) {
        final value = row[key];
        if (value != null) return value;
      }
      return null;
    }

    final rawSize = pick(const ['size', 'file_size', 'fileSize']);
    final rawTime = pick(const ['timestamp', 'created_at', 'date', 'time']);

    DateTime? time;
    if (rawTime is int) {
      time = DateTime.fromMillisecondsSinceEpoch(rawTime);
    } else if (rawTime is String) {
      time = DateTime.tryParse(rawTime);
    }

    return _Transfer(
      name: '${pick(const ['file_name', 'fileName', 'name']) ?? 'Unknown file'}',
      sent: row['direction'] == 'Sent',
      size: rawSize is int ? _formatBytes(rawSize) : rawSize?.toString(),
      when: time == null ? null : _formatWhen(time),
    );
  }
}

String _formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}

String _formatWhen(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final days = today.difference(day).inDays;

  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[time.weekday - 1];
  }
  return '${time.day}/${time.month}/${time.year}';
}