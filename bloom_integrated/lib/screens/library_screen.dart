// lib/screens/library_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'pdf_viewer_screen.dart';
import 'file_viewer_screen.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/common_widgets.dart';
import '../services/activity_service.dart';
import 'assessment_screen.dart';
import '../services/badge_service.dart';

final _supabase = Supabase.instance.client;

enum ProgressFilter { all, notStarted, inProgress, completed }

class _LibraryFilters {
  final ProgressFilter progress;
  final String? categoryName;
  final String? author;
  final String? dateFrom;
  final String? dateTo;

  const _LibraryFilters({
    this.progress = ProgressFilter.all,
    this.categoryName,
    this.author,
    this.dateFrom,
    this.dateTo,
  });

  _LibraryFilters copyWith({
    ProgressFilter? progress,
    Object? categoryName = _sentinel,
    Object? author       = _sentinel,
    Object? dateFrom     = _sentinel,
    Object? dateTo       = _sentinel,
  }) {
    return _LibraryFilters(
      progress:     progress     ?? this.progress,
      categoryName: categoryName == _sentinel ? this.categoryName : categoryName as String?,
      author:       author       == _sentinel ? this.author       : author       as String?,
      dateFrom:     dateFrom     == _sentinel ? this.dateFrom     : dateFrom     as String?,
      dateTo:       dateTo       == _sentinel ? this.dateTo       : dateTo       as String?,
    );
  }

  bool get hasActiveFilters =>
      progress != ProgressFilter.all ||
      categoryName != null ||
      author != null ||
      dateFrom != null ||
      dateTo != null;
}

const _sentinel = Object();

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<ModuleModel> _modules     = [];
  Map<String, int>  _progressMap = {};
  bool   _loading     = true;
  bool   _loadingMore = false;
  bool   _hasMore     = true;
  String _search      = '';
  int    _page        = 0;
  static const int _pageSize = 10;

  _LibraryFilters _filters = const _LibraryFilters();

  List<ModuleModel> _continueModules = [];
  int  _completedTotal  = 0;
  int  _inProgressTotal = 0;
  int  _badgeCount       = 0;
  bool _statsLoading     = true;

  ModuleModel? _selectedModule;
  Map<String, dynamic>? _selectedRaw;
  List<Map<String, dynamic>> _moduleFiles = [];
  bool _loadingFiles = false;

  final _scrollController = ScrollController();
  final _searchCtrl = TextEditingController();

  List<String> get _categories {
    final cats = _modules.map((m) => m.category).where((c) => c.isNotEmpty).toSet().toList();
    cats.sort();
    return cats;
  }

  List<String> get _authors {
    final authors = _modules
        .map((m) => m.author ?? '')
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList();
    authors.sort();
    return authors;
  }

  bool get _railVisible =>
      !_filters.hasActiveFilters && _search.isEmpty && _continueModules.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
    _loadStats();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore && _hasMore && _search.isEmpty && !_filters.hasActiveFilters) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _page = 0; _hasMore = true; });
    try {
      final userId = _supabase.auth.currentUser?.id;
      final modulesData = await _supabase
          .from('modules')
          .select('*, categories(name), module_files(count), assessments(id), author, published_date, tags')
          .eq('status', 'published')
          .order('created_at', ascending: false)
          .range(0, _pageSize - 1);

      Map<String, int> progressMap = {};
      if (userId != null) {
        final progressData = await _supabase
            .from('module_progress')
            .select('module_id, progress_percent')
            .eq('user_id', userId);
        for (final p in progressData as List) {
          progressMap[p['module_id'].toString()] = (p['progress_percent'] as num?)?.toInt() ?? 0;
        }
      }

      if (mounted) {
        final list = (modulesData as List)
            .map((m) => ModuleModel.fromMap(m, progress: progressMap[m['id'].toString()] ?? 0))
            .toList();
        setState(() {
          _progressMap = progressMap;
          _modules     = list;
          _hasMore     = list.length == _pageSize;
          _loading     = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final nextPage = _page + 1;
      final from = nextPage * _pageSize;
      final to   = from + _pageSize - 1;
      final modulesData = await _supabase
          .from('modules')
          .select('*, categories(name), module_files(count), assessments(id), author, published_date, tags')
          .eq('status', 'published')
          .order('created_at', ascending: false)
          .range(from, to);
      if (mounted) {
        final list = (modulesData as List)
            .map((m) => ModuleModel.fromMap(m, progress: _progressMap[m['id'].toString()] ?? 0))
            .toList();
        setState(() {
          _modules.addAll(list);
          _page        = nextPage;
          _hasMore     = list.length == _pageSize;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadStats() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _statsLoading = false);
      return;
    }
    try {
      final completedRows = await _supabase
          .from('module_progress')
          .select('id')
          .eq('user_id', userId)
          .eq('status', 'completed');

      final inProgressRows = await _supabase
          .from('module_progress')
          .select('module_id, progress_percent, last_accessed_at')
          .eq('user_id', userId)
          .eq('status', 'in_progress')
          .order('last_accessed_at', ascending: false);

      final badgesData = await _supabase
          .from('student_badges')
          .select('id')
          .eq('user_id', userId);

      final continueModules = <ModuleModel>[];
      for (final r in (inProgressRows as List).take(5)) {
        final mid = r['module_id'].toString();
        final raw = await _supabase
            .from('modules')
            .select('*, categories(name), author, published_date, tags')
            .eq('id', mid)
            .maybeSingle();
        if (raw != null) {
          final pct = (r['progress_percent'] as num?)?.toInt() ?? 0;
          continueModules.add(ModuleModel.fromMap(raw, progress: pct));
        }
      }

      if (mounted) {
        setState(() {
          _completedTotal   = (completedRows as List).length;
          _inProgressTotal  = inProgressRows.length;
          _badgeCount        = (badgesData as List).length;
          _continueModules   = continueModules;
          _statsLoading      = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  Future<void> _handleOpen(ModuleModel module) async {
    final raw = await _supabase
        .from('modules')
        .select('author, published_date, tags')
        .eq('id', module.id)
        .maybeSingle();
    _openModule(module, raw ?? {});
  }

  Future<void> _openModule(ModuleModel module, Map<String, dynamic> raw) async {
    setState(() {
      _selectedModule = module;
      _selectedRaw    = raw;
      _loadingFiles   = true;
      _moduleFiles    = [];
    });

    await ActivityService.log(
      activityType:  'module_opened',
      referenceId:   module.id,
      referenceType: 'module',
      metadata: {'title': module.title},
    );

    try {
      final files = await _supabase
          .from('module_files')
          .select('*')
          .eq('module_id', module.id)
          .order('sort_order');
      if (mounted) {
        setState(() {
          _moduleFiles  = List<Map<String, dynamic>>.from(files as List);
          _loadingFiles = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  // Routes to the correct viewer based on file type. PDFs use the
  // existing in-app PDFView; every other type uses FileViewerScreen
  // (image preview, or a file-info card for video/PPTX/DOCX/etc).
  // Both viewers expose the same download icon button in their app bar.
  Future<void> _openFile(Map<String, dynamic> file) async {
    final url = file['file_url']?.toString();
    if (url == null || url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File URL not available.')));
      }
      return;
    }

    final fileName = file['file_name']?.toString() ?? 'File';
    final fileType = file['file_type']?.toString() ?? '';
    final isPdf = fileType.toLowerCase().contains('pdf') ||
        fileName.toLowerCase().endsWith('.pdf');

    await ActivityService.log(
      activityType:  'file_opened',
      referenceId:   file['id']?.toString(),
      referenceType: 'module_file',
      metadata: {'file_name': fileName, 'module_id': file['module_id']},
    );

    if (!mounted) return;

    if (isPdf) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => PdfViewerScreen(
          url: url,
          title: fileName,
          onComplete: () => _updateProgress(_selectedModule!.id, 100),
        ),
      ));
    } else {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => FileViewerScreen(
          url: url,
          title: fileName,
          fileType: fileType,
        ),
      ));
    }
  }

  Future<void> _updateProgress(String moduleId, int pct) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    try {
      await _supabase.from('module_progress').upsert({
        'user_id':          userId,
        'module_id':        moduleId,
        'progress_percent': pct,
        'status':           pct == 100 ? 'completed' : 'in_progress',
        'last_accessed_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,module_id');
      if (pct == 100) {
        final unlocked = await BadgeService.checkAndAward();
        if (unlocked.isNotEmpty && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('🏅 Badge unlocked: ${unlocked.join(', ')}'),
            backgroundColor: AppColors.primary,
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
      await _load();
      await _loadStats();
    } catch (_) {}
  }

  List<ModuleModel> get _filtered {
    return _modules.where((m) {
      if (_search.isNotEmpty) {
        final q = _search.toLowerCase();
        final matchTitle    = m.title.toLowerCase().contains(q);
        final matchCategory = m.category.toLowerCase().contains(q);
        final matchAuthor   = (m.author ?? '').toLowerCase().contains(q);
        final matchTags     = (m.tags ?? []).any((t) => t.toLowerCase().contains(q));
        if (!matchTitle && !matchCategory && !matchAuthor && !matchTags) return false;
      }
      if (_filters.categoryName != null && m.category != _filters.categoryName) return false;
      if (_filters.author != null && (m.author ?? '') != _filters.author) return false;
      if (_filters.dateFrom != null && m.publishedDate != null) {
        if (m.publishedDate!.compareTo(_filters.dateFrom!) < 0) return false;
      }
      if (_filters.dateTo != null && m.publishedDate != null) {
        if (m.publishedDate!.compareTo(_filters.dateTo!) > 0) return false;
      }
      switch (_filters.progress) {
        case ProgressFilter.notStarted: if (m.progress > 0) return false; break;
        case ProgressFilter.inProgress: if (m.progress == 0 || m.progress == 100) return false; break;
        case ProgressFilter.completed:  if (m.progress < 100) return false; break;
        default: break;
      }
      return true;
    }).toList();
  }

  int get _activeFilterCount {
    int count = 0;
    if (_filters.progress != ProgressFilter.all) count++;
    if (_filters.categoryName != null) count++;
    if (_filters.author != null) count++;
    if (_filters.dateFrom != null || _filters.dateTo != null) count++;
    return count;
  }

  void _clearFilters() => setState(() => _filters = const _LibraryFilters());

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _FilterSheet(
        authors: _authors,
        currentFilters: _filters,
        onApply: (f) => setState(() => _filters = f),
      ),
    );
  }

  String _progressLabel(ProgressFilter f) {
    switch (f) {
      case ProgressFilter.notStarted: return 'Not Started';
      case ProgressFilter.inProgress: return 'In Progress';
      case ProgressFilter.completed:  return 'Completed';
      default: return 'All';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedModule != null) return _buildModuleDetail(_selectedModule!);
    return _buildLibrary();
  }

  Widget _buildLibrary() {
    return Column(
      children: [
        _header(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
              : RefreshIndicator(
                  onRefresh: () async {
                    await _load();
                    await _loadStats();
                  },
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_railVisible) _continueRail(),
                        _statusBar(),
                        _categoryBar(),
                        if (_filters.author != null ||
                            _filters.dateFrom != null ||
                            _filters.dateTo != null)
                          _buildActiveFiltersRow(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                        '${_filtered.length} of ${_modules.length} loaded modules',
                                        style: GoogleFonts.nunito(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textLight)),
                                  ),
                                  if (_filters.hasActiveFilters)
                                    GestureDetector(
                                      onTap: _clearFilters,
                                      behavior: HitTestBehavior.opaque,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4, horizontal: 2),
                                        child: Text('Clear filters',
                                            style: GoogleFonts.nunito(
                                                fontSize: 12,
                                                color: AppColors.primary,
                                                fontWeight: FontWeight.w800)),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (_filtered.isEmpty)
                                _emptyState()
                              else
                                ..._filtered.map((m) => Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: _ModuleCard(
                                        module: m,
                                        onOpen: () => _handleOpen(m),
                                      ),
                                    )),
                              if (_loadingMore)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                      child: CircularProgressIndicator(
                                          color: AppColors.primary, strokeWidth: 2)),
                                ),
                              if (!_hasMore &&
                                  _modules.isNotEmpty &&
                                  _search.isEmpty &&
                                  !_filters.hasActiveFilters)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: Text('All ${_modules.length} modules loaded',
                                        style: GoogleFonts.nunito(
                                            fontSize: 12, color: AppColors.textLight)),
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
      ],
    );
  }

  Widget _header() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Library',
                  style: GoogleFonts.nunito(
                      color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text('Learning modules & resources',
                  style: GoogleFonts.nunito(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 14),
              _statsLoading
                  ? const SizedBox(height: 62)
                  : Row(children: [
                      _stat(Icons.task_alt_rounded, '$_completedTotal', 'Completed'),
                      const SizedBox(width: 10),
                      _stat(Icons.autorenew_rounded, '$_inProgressTotal', 'In progress'),
                      const SizedBox(width: 10),
                      _stat(Icons.workspace_premium_rounded, '$_badgeCount', 'Badges'),
                    ]),
              const SizedBox(height: 14),
              _searchBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(height: 2),
          Text(value,
              style: GoogleFonts.nunito(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
          Text(label,
              style: GoogleFonts.nunito(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 9,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _searchBar() {
    final moreFiltersActive =
        _filters.author != null || _filters.dateFrom != null || _filters.dateTo != null;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Icon(Icons.search_rounded, color: Colors.white.withValues(alpha: 0.85), size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            style: GoogleFonts.nunito(
                color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
            cursorColor: Colors.white,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search modules',
              hintStyle: GoogleFonts.nunito(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ),
        if (_search.isNotEmpty)
          GestureDetector(
            onTap: () {
              _searchCtrl.clear();
              setState(() => _search = '');
            },
            child: Icon(Icons.close_rounded, color: Colors.white.withValues(alpha: 0.85), size: 18),
          ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _showFilterSheet,
          child: Stack(clipBehavior: Clip.none, children: [
            Icon(Icons.tune_rounded, color: Colors.white.withValues(alpha: 0.9), size: 20),
            if (moreFiltersActive)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _continueRail() {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _RailTitle('Pick up where you left off'),
          ),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _continueModules.take(5).length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => _ResumeCard(
                module: _continueModules[i],
                onTap: () => _handleOpen(_continueModules[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    const options = [
      ProgressFilter.all,
      ProgressFilter.inProgress,
      ProgressFilter.completed,
      ProgressFilter.notStarted,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: options.map((f) {
            final active = _filters.progress == f;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(() => _filters = _filters.copyWith(progress: f)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: active ? AppColors.primary : Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: active ? AppColors.primary : AppColors.border, width: 1.5),
                  ),
                  child: Text(_progressLabel(f),
                      style: GoogleFonts.nunito(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: active ? Colors.white : AppColors.textMid)),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _categoryBar() {
    final cats = ['All', ..._categories];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: cats.map((c) {
            final active =
                c == 'All' ? _filters.categoryName == null : _filters.categoryName == c;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(
                    () => _filters = _filters.copyWith(categoryName: c == 'All' ? null : c)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.primary.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(c,
                      style: GoogleFonts.nunito(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: active ? AppColors.primaryDark : AppColors.textLight)),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// Chips for filters chosen in the filter sheet (author, date range).
  /// Progress and category aren't repeated here — they're already shown
  /// as selected chips in the two rows above.
  Widget _buildActiveFiltersRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (_filters.author != null)
            _ActiveChipWithIcon(
              icon: Icons.person_outline,
              label: _filters.author!,
              onRemove: () =>
                  setState(() => _filters = _filters.copyWith(author: null)),
            ),
          if (_filters.dateFrom != null || _filters.dateTo != null)
            _ActiveChipWithIcon(
              icon: Icons.calendar_today_outlined,
              label: '${_filters.dateFrom ?? '...'} → ${_filters.dateTo ?? '...'}',
              onRemove: () => setState(() =>
                  _filters = _filters.copyWith(dateFrom: null, dateTo: null)),
            ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final filtered = _filters.hasActiveFilters || _search.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      alignment: Alignment.center,
      child: Column(children: [
        Icon(filtered ? Icons.search_off_rounded : Icons.menu_book_outlined,
            color: AppColors.textLight, size: 36),
        const SizedBox(height: 8),
        Text(filtered ? 'No modules match your filters' : 'No modules found',
            style: GoogleFonts.nunito(
                fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textLight)),
        if (_filters.hasActiveFilters) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: _clearFilters,
            child: Text('Clear filters',
                style: GoogleFonts.nunito(
                    color: AppColors.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    );
  }

  Widget _buildModuleDetail(ModuleModel module) {
    final progress = _progressMap[module.id] ?? 0;
    final raw      = _selectedRaw ?? {};
    final author   = raw['author'] as String?;
    final pubDate  = raw['published_date'] as String?;
    final tags     = raw['tags'] as List?;

    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [AppColors.primaryDark, AppColors.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
          ),
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                IconButton(
                  onPressed: () => setState(
                      () {_selectedModule = null; _selectedRaw = null;}),
                  icon: const Icon(Icons.chevron_left, color: Colors.white),
                ),
                Expanded(
                  child: Text(module.title,
                      style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16),
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      BadgeChip(
                          label: module.category,
                          color: Colors.white.withValues(alpha: 0.3)),
                      const SizedBox(width: 8),
                      BadgeChip(
                          label: progress == 100
                              ? 'Completed'
                              : '$progress%',
                          color: Colors.white.withValues(alpha: 0.3)),
                      if (progress == 100) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.check_circle,
                            color: Colors.white, size: 14),
                      ],
                    ]),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: progress / 100,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white),
                        minHeight: 6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('About this Module',
                        style: GoogleFonts.nunito(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: AppColors.textDark)),
                    const SizedBox(height: 8),
                    if (module.description != null &&
                          module.description!.isNotEmpty) ...[
                        _ExpandableDescription(description: module.description!),
                        const SizedBox(height: 12),
                      ],
                    if (author != null || pubDate != null) ...[
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Wrap(spacing: 16, runSpacing: 8, children: [
                        if (author != null && author.isNotEmpty)
                          _MetaChip(
                              icon: Icons.person_outline, label: author),
                        if (pubDate != null && pubDate.isNotEmpty)
                          _MetaChip(
                              icon: Icons.calendar_today_outlined,
                              label: _formatDate(pubDate)),
                      ]),
                    ],
                    if (tags != null && tags.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ...tags.map((tag) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color:
                                  AppColors.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppColors.primary
                                      .withValues(alpha: 0.2)),
                            ),
                            child: Text('#$tag',
                                style: GoogleFonts.nunito(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary)),
                          )),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 12),

              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(children: [
                          const Icon(Icons.folder_open_outlined,
                              size: 18, color: AppColors.textDark),
                          const SizedBox(width: 6),
                          Text('Module Files',
                              style: GoogleFonts.nunito(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  color: AppColors.textDark)),
                        ]),
                        if (_moduleFiles.isNotEmpty)
                          Text(
                              '${_moduleFiles.length} file${_moduleFiles.length > 1 ? 's' : ''}',
                              style: GoogleFonts.nunito(
                                  fontSize: 12,
                                  color: AppColors.textLight)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_loadingFiles)
                      const Center(
                          child: CircularProgressIndicator(
                              color: AppColors.primary))
                    else if (_moduleFiles.isEmpty)
                      Column(children: [
                        const Icon(Icons.folder_open_outlined,
                            size: 36, color: AppColors.textLight),
                        const SizedBox(height: 8),
                        Text('No files uploaded yet.',
                            style: GoogleFonts.nunito(
                                color: AppColors.textLight,
                                fontSize: 13)),
                      ])
                    else
                      ..._moduleFiles.map(
                          (f) => _FileTile(
                                file:   f,
                                onTap: () => _openFile(f),
                              )),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AssessmentScreen(
                          moduleId:    module.id,
                          moduleTitle: module.title,
                          onComplete: () {
                            Navigator.pop(context);
                            _load();
                            _loadStats();
                          },
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.quiz_outlined,
                      size: 20, color: AppColors.primary),
                  label: Text('Take Assessment',
                      style: GoogleFonts.nunito(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppColors.primary)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(
                        color: AppColors.primary, width: 1.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDate(String iso) {
    try {
      final d = DateTime.parse(iso);
      const months = [
        'Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'
      ];
      return '${d.day} ${months[d.month - 1]} ${d.year}';
    } catch (_) {
      return iso;
    }
  }
}

class _RailTitle extends StatelessWidget {
  final String text;
  const _RailTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: GoogleFonts.nunito(
          fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textDark));
}

class _ResumeCard extends StatelessWidget {
  final ModuleModel module;
  final VoidCallback onTap;
  const _ResumeCard({required this.module, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 220,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primaryDark, AppColors.primary],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(module.category,
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        )),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 34,
                    child: Text(module.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                        )),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  AppProgressBar(value: module.progress, color: AppColors.accent),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${module.progress}% complete',
                          style: GoogleFonts.nunito(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textLight,
                          )),
                      Row(
                        children: [
                          Text('Resume',
                              style: GoogleFonts.nunito(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary,
                              )),
                          const Icon(Icons.play_arrow_rounded,
                              color: AppColors.primary, size: 13),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  final ModuleModel module;
  final VoidCallback onOpen;
  const _ModuleCard({required this.module, required this.onOpen});

  String get _statusLabel =>
      module.progress == 100 ? 'Completed' : module.progress > 0 ? 'In progress' : 'Not started';

  Color get _statusColor {
    if (module.progress == 100) return AppColors.primary;
    if (module.progress > 0) return AppColors.accent;
    return AppColors.textLight;
  }

  ({String label, IconData icon}) get _action {
    if (module.progress == 100) return (label: 'Review', icon: Icons.check_rounded);
    if (module.progress > 0) return (label: 'Resume module', icon: Icons.play_arrow_rounded);
    return (label: 'Start module', icon: Icons.arrow_forward_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final notStarted = module.progress == 0;
    final completed  = module.progress == 100;
    final act         = _action;
    final color       = Color(module.colorValue);

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.menu_book_outlined, color: color, size: 26),
                  ),
                  if (completed)
                    Positioned(
                      top: -5,
                      right: -5,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(Icons.check_rounded,
                            color: Colors.white, size: 13),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(module.category,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.nunito(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryLight,
                              )),
                        ),
                        BadgeChip(label: _statusLabel, color: _statusColor),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(module.title,
                        style: GoogleFonts.nunito(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textDark,
                          height: 1.3,
                        )),
                    if ((module.author ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(children: [
                        const Icon(Icons.person_outline,
                            color: AppColors.textLight, size: 14),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(module.author!,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.nunito(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textLight,
                              )),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (module.progress > 0 && module.progress < 100) ...[
            const SizedBox(height: 12),
            AppProgressBar(value: module.progress, color: AppColors.accent),
            const SizedBox(height: 4),
            Text('${module.progress}% complete',
                style: GoogleFonts.nunito(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textLight,
                )),
          ],
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: notStarted
                    ? AppColors.background
                    : _statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(act.icon,
                      size: 16,
                      color: notStarted ? AppColors.primaryDark : _statusColor),
                  const SizedBox(width: 7),
                  Text(act.label,
                      style: GoogleFonts.nunito(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: notStarted ? AppColors.primaryDark : _statusColor,
                      )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: AppColors.primary),
      const SizedBox(width: 5),
      Flexible(
        child: Text(
          label,
          style: GoogleFonts.nunito(
              fontSize: 12,
              color: AppColors.textMid,
              fontWeight: FontWeight.w600),
          softWrap: true,
        ),
      ),
    ]);
  }
}

class _ActiveChipWithIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onRemove;
  const _ActiveChipWithIcon({
    required this.icon,
    required this.label,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: AppColors.primary),
        const SizedBox(width: 4),
        Text(label,
            style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primary)),
        const SizedBox(width: 5),
        GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close,
                size: 14, color: AppColors.primary)),
      ]),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  final List<String> authors;
  final _LibraryFilters currentFilters;
  final ValueChanged<_LibraryFilters> onApply;
  const _FilterSheet({
    required this.authors,
    required this.currentFilters,
    required this.onApply,
  });
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late _LibraryFilters _local;

  @override
  void initState() {
    super.initState();
    _local = widget.currentFilters;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Text('More Filters',
                      style: GoogleFonts.nunito(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textDark)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _local = _local.copyWith(
                        author: null, dateFrom: null, dateTo: null)),
                    child: Text('Reset',
                        style: GoogleFonts.nunito(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
              ],
            ),
          ),

          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.authors.isNotEmpty) ...[
                    Text('Author',
                        style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textMid)),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (context, constraints) => Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _SheetChip(
                            label: 'All',
                            selected: _local.author == null,
                            maxWidth: constraints.maxWidth,
                            onTap: () => setState(
                                () => _local = _local.copyWith(author: null)),
                          ),
                          ...widget.authors.map((a) => _SheetChip(
                                label: a,
                                icon: Icons.person_outline,
                                selected: _local.author == a,
                                maxWidth: constraints.maxWidth,
                                onTap: () => setState(
                                    () => _local = _local.copyWith(author: a)),
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  Text('Publication Date Range',
                      style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textMid)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('From',
                              style: GoogleFonts.nunito(
                                  fontSize: 11, color: AppColors.textLight)),
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _local.dateFrom != null
                                    ? DateTime.tryParse(_local.dateFrom!) ??
                                        DateTime.now()
                                    : DateTime(2020),
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                                builder: (ctx, child) => Theme(
                                  data: Theme.of(ctx).copyWith(
                                      colorScheme: const ColorScheme.light(
                                          primary: AppColors.primary)),
                                  child: child!,
                                ),
                              );
                              if (picked != null) {
                                setState(() => _local = _local.copyWith(
                                    dateFrom: picked
                                        .toIso8601String()
                                        .split('T')[0]));
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: _local.dateFrom != null
                                    ? AppColors.primary.withValues(alpha: 0.08)
                                    : AppColors.background,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: _local.dateFrom != null
                                        ? AppColors.primary
                                        : AppColors.border),
                              ),
                              child: Row(children: [
                                Icon(Icons.calendar_today_outlined,
                                    size: 14,
                                    color: _local.dateFrom != null
                                        ? AppColors.primary
                                        : AppColors.textLight),
                                const SizedBox(width: 6),
                                Text(
                                  _local.dateFrom ?? 'Select date',
                                  style: GoogleFonts.nunito(
                                    fontSize: 12,
                                    color: _local.dateFrom != null
                                        ? AppColors.primary
                                        : AppColors.textLight,
                                    fontWeight: _local.dateFrom != null
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                                if (_local.dateFrom != null) ...[
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () => setState(() => _local =
                                        _local.copyWith(dateFrom: null)),
                                    child: const Icon(Icons.close,
                                        size: 14, color: AppColors.primary),
                                  ),
                                ],
                              ]),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('To',
                              style: GoogleFonts.nunito(
                                  fontSize: 11, color: AppColors.textLight)),
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _local.dateTo != null
                                    ? DateTime.tryParse(_local.dateTo!) ??
                                        DateTime.now()
                                    : DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now(),
                                builder: (ctx, child) => Theme(
                                  data: Theme.of(ctx).copyWith(
                                      colorScheme: const ColorScheme.light(
                                          primary: AppColors.primary)),
                                  child: child!,
                                ),
                              );
                              if (picked != null) {
                                setState(() => _local = _local.copyWith(
                                    dateTo: picked
                                        .toIso8601String()
                                        .split('T')[0]));
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: _local.dateTo != null
                                    ? AppColors.primary.withValues(alpha: 0.08)
                                    : AppColors.background,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: _local.dateTo != null
                                        ? AppColors.primary
                                        : AppColors.border),
                              ),
                              child: Row(children: [
                                Icon(Icons.calendar_today_outlined,
                                    size: 14,
                                    color: _local.dateTo != null
                                        ? AppColors.primary
                                        : AppColors.textLight),
                                const SizedBox(width: 6),
                                Text(
                                  _local.dateTo ?? 'Select date',
                                  style: GoogleFonts.nunito(
                                    fontSize: 12,
                                    color: _local.dateTo != null
                                        ? AppColors.primary
                                        : AppColors.textLight,
                                    fontWeight: _local.dateTo != null
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                                if (_local.dateTo != null) ...[
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () => setState(() =>
                                        _local = _local.copyWith(dateTo: null)),
                                    child: const Icon(Icons.close,
                                        size: 14, color: AppColors.primary),
                                  ),
                                ],
                              ]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ]),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  widget.onApply(_local);
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text('Apply Filters',
                    style: GoogleFonts.nunito(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final double? maxWidth;
  const _SheetChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth != null
              ? (maxWidth! - 16).clamp(120, 260)
              : 240,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.1)
                : AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? AppColors.primary : AppColors.border,
                width: selected ? 1.5 : 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1.5),
                  child: Icon(icon,
                      size: 13,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textMid),
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  label,
                  softWrap: true,
                  style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textMid),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// File row — purely navigational. Tapping opens the appropriate
// viewer (PdfViewerScreen for PDFs, FileViewerScreen for everything
// else). Downloading is a separate, explicit action available as an
// icon button inside whichever viewer opens — not triggered by tapping
// this row, and no longer tracked/cached here.
class _FileTile extends StatelessWidget {
  final Map<String, dynamic> file;
  final VoidCallback onTap;
  const _FileTile({required this.file, required this.onTap});

  bool get _isPdf {
    final type = (file['file_type'] ?? '').toString().toLowerCase();
    final name = (file['file_name'] ?? '').toString().toLowerCase();
    return type.contains('pdf') || name.endsWith('.pdf');
  }

  IconData get _icon {
    final type = (file['file_type'] ?? '').toString().toLowerCase();
    final name = (file['file_name'] ?? '').toString().toLowerCase();
    if (type.contains('pdf') || name.endsWith('.pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    if (type.contains('video') || name.endsWith('.mp4')) {
      return Icons.play_circle_outline;
    }
    if (type.contains('image') ||
        name.endsWith('.png') ||
        name.endsWith('.jpg')) {
      return Icons.image_outlined;
    }
    if (name.endsWith('.pptx') || name.endsWith('.ppt')) {
      return Icons.slideshow_outlined;
    }
    if (name.endsWith('.docx') || name.endsWith('.doc')) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Color get _iconColor {
    final type = (file['file_type'] ?? '').toString().toLowerCase();
    final name = (file['file_name'] ?? '').toString().toLowerCase();
    if (type.contains('pdf') || name.endsWith('.pdf')) {
      return Colors.red.shade400;
    }
    if (type.contains('video') || name.endsWith('.mp4')) {
      return Colors.blue.shade400;
    }
    if (name.endsWith('.pptx') || name.endsWith('.ppt')) {
      return Colors.orange.shade400;
    }
    if (name.endsWith('.docx') || name.endsWith('.doc')) {
      return Colors.blue.shade600;
    }
    return AppColors.primary;
  }

  String get _fileSize {
    final kb = file['file_size_kb'];
    if (kb == null) return '';
    if (kb < 1024) return '$kb KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: _iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(_icon, color: _iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(file['file_name'] ?? 'File',
                      style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark),
                      overflow: TextOverflow.ellipsis),
                  if (_fileSize.isNotEmpty)
                    Text(_fileSize,
                        style: GoogleFonts.nunito(
                            fontSize: 11, color: AppColors.textLight)),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                  _isPdf ? Icons.picture_as_pdf_outlined : Icons.visibility_outlined,
                  size: 14,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  'View',
                  style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandableDescription extends StatefulWidget {
  final String description;
  const _ExpandableDescription({required this.description});

  @override
  State<_ExpandableDescription> createState() => _ExpandableDescriptionState();
}

class _ExpandableDescriptionState extends State<_ExpandableDescription> {
  static const int _collapsedMaxLines = 4;
  bool _expanded = false;
  bool _isOverflowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tp = TextPainter(
        text: TextSpan(
          text: widget.description,
          style: GoogleFonts.nunito(
              fontSize: 13, color: AppColors.textMid, height: 1.5),
        ),
        maxLines: _collapsedMaxLines,
        textDirection: TextDirection.ltr,
      )..layout(
          maxWidth: MediaQuery.of(context).size.width - 72,
        );
      if (tp.didExceedMaxLines && mounted) {
        setState(() => _isOverflowing = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedCrossFade(
          firstChild: Text(
            widget.description,
            maxLines: _collapsedMaxLines,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.nunito(
                fontSize: 13, color: AppColors.textMid, height: 1.5),
          ),
          secondChild: Text(
            widget.description,
            style: GoogleFonts.nunito(
                fontSize: 13, color: AppColors.textMid, height: 1.5),
          ),
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
        if (_isOverflowing) ...[
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _expanded ? 'Show less' : 'Show more',
                  style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary),
                ),
                const SizedBox(width: 3),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}