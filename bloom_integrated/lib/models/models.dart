class ModuleModel {
  final String id;
  final String title;
  final String category;
  final int progress;
  final String status;
  final int colorValue;
  final int pages;
  final bool hasBadge;
  final String? description;
  final String? author;
  final String? publishedDate;
  final List<String>? tags;

  const ModuleModel({
    required this.id,
    required this.title,
    required this.category,
    required this.progress,
    required this.status,
    required this.colorValue,
    this.pages = 0,
    this.hasBadge = false,
    this.description,
    this.author,
    this.publishedDate,
    this.tags,
  });

  factory ModuleModel.fromMap(Map<String, dynamic> map, {int progress = 0}) {
    // Parse tags — stored as PostgreSQL array (List) or null
    List<String>? tags;
    if (map['tags'] != null) {
      tags = (map['tags'] as List).map((t) => t.toString()).toList();
    }

    return ModuleModel(
      id:            map['id']?.toString() ?? '',
      title:         map['title'] ?? 'Untitled Module',
      category:      map['categories']?['name'] ?? map['category'] ?? 'General',
      progress:      progress,
      status:        map['status'] ?? 'published',
      colorValue:    0xFF40916C,
      pages:         map['pages'] ?? 0,
      hasBadge:      progress == 100,
      description:   map['description'] as String?,
      author:        map['author'] as String?,
      publishedDate: map['published_date'] as String?,
      tags:          tags,
    );
  }
}

class SeminarModel {
  final String id;
  final String title;
  final String date;
  final String time;
  final String speaker;
  final String type;
  final int participants;
  final int colorValue;

  const SeminarModel({
    required this.id,
    required this.title,
    required this.date,
    required this.time,
    required this.speaker,
    required this.type,
    required this.participants,
    required this.colorValue,
  });

  factory SeminarModel.fromMap(Map<String, dynamic> map) {
    final rawDate = map['scheduled_start'] ?? map['scheduled_at'] ?? map['date'] ?? '';
    final dateStr = rawDate.toString().isNotEmpty
        ? rawDate.toString().substring(0, 10)
        : 'TBA';
    return SeminarModel(
      id:           map['id']?.toString() ?? '',
      title:        map['title'] ?? 'Untitled Seminar',
      date:         dateStr,
      time:         map['time'] ?? '',
      speaker:      map['speaker'] ?? '',
      type:         map['status'] == 'active' ? 'Live' : 'Upcoming',
      participants: map['participants_count'] ?? 0,
      colorValue:   0xFF2D6A4F,
    );
  }
}

class EventModel {
  final String id;
  final String title;

  /// Short form kept for existing screens, e.g. "10-25".
  final String date;

  /// Readable form for display, e.g. "Oct 25, 2026". Empty if unparseable.
  final String dateLabel;

  final String category;
  final int colorValue;

  const EventModel({
    required this.id,
    required this.title,
    required this.date,
    this.dateLabel = '',
    required this.category,
    required this.colorValue,
  });

  factory EventModel.fromMap(Map<String, dynamic> map) {
    final raw = (map['start_date'] ?? map['start_time'] ?? map['date'] ?? '').toString();
    final dateStr = raw.length >= 10 ? raw.substring(5, 10) : '';

    String label = '';
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      final d = parsed.toLocal();
      label = '${months[d.month - 1]} ${d.day}, ${d.year}';
    }

    return EventModel(
      id:         map['id']?.toString() ?? '',
      title:      map['title'] ?? 'Untitled Event',
      date:       dateStr,
      dateLabel:  label,
      category:   map['category'] ?? 'Event',
      colorValue: 0xFFF4A261,
    );
  }
}

class BadgeModel {
  final String id;
  final String name;
  final String description;
  final String icon;
  final bool earned;
  final int colorValue;

  const BadgeModel({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.earned,
    required this.colorValue,
  });

  factory BadgeModel.fromMap(Map<String, dynamic> map, {bool earned = false}) {
    return BadgeModel(
      id:          map['id']?.toString() ?? '',
      name:        map['name'] ?? 'Badge',
      description: map['description'] ?? '',
      icon:        map['icon'] ?? 'military_tech',
      earned:      earned,
      colorValue:  0xFF40916C,
    );
  }
}

class CertificateModel {
  final String id;
  final String title;
  final String date;
  final String issuer;
  final int colorValue;

  const CertificateModel({
    required this.id,
    required this.title,
    required this.date,
    required this.issuer,
    required this.colorValue,
  });

  factory CertificateModel.fromMap(Map<String, dynamic> map) {
    final raw = map['issued_at'] ?? map['date'] ?? '';
    final dateStr = raw.toString().length >= 10 ? raw.toString().substring(0, 10) : '';
    return CertificateModel(
      id:         map['id']?.toString() ?? '',
      title:      map['title'] ?? 'Certificate',
      date:       dateStr,
      issuer:     map['issuer'] ?? 'GADRC CvSU',
      colorValue: 0xFF2D6A4F,
    );
  }
}

class ForumPost {
  final String id;
  final String title;
  final String body;
  final String authorId;
  final String authorName;
  final String? authorAvatar;
  final DateTime createdAt;
  final int likesCount;
  final int commentsCount;
  final bool isLiked;
  final String? category;

  const ForumPost({
    required this.id,
    required this.title,
    required this.body,
    required this.authorId,
    required this.authorName,
    this.authorAvatar,
    required this.createdAt,
    this.likesCount = 0,
    this.commentsCount = 0,
    this.isLiked = false,
    this.category,
  });

  factory ForumPost.fromMap(Map<String, dynamic> map, {bool isLiked = false}) {
    return ForumPost(
      id:            map['id']?.toString() ?? '',
      title:         map['title'] ?? '',
      body:          map['body'] ?? map['content'] ?? '',
      authorId:      map['author_id']?.toString() ?? map['user_id']?.toString() ?? '',
      authorName:    map['profiles']?['full_name'] ?? map['author_name'] ?? 'Anonymous',
      authorAvatar:  map['profiles']?['avatar_url'],
      createdAt:     map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
      likesCount:    map['likes_count'] ?? 0,
      commentsCount: map['comments_count'] ?? 0,
      isLiked:       isLiked,
      category:      map['category'],
    );
  }
}

class StudentProfile {
  final String id;
  final String fullName;
  final String studentId;
  final String courseYear;
  final String email;
  final String? avatarUrl;

  const StudentProfile({
    required this.id,
    required this.fullName,
    required this.studentId,
    required this.courseYear,
    required this.email,
    this.avatarUrl,
  });

  factory StudentProfile.fromMap(Map<String, dynamic> map) {
    return StudentProfile(
      id:         map['id']?.toString() ?? '',
      fullName:   map['full_name'] ?? 'Student',
      studentId:  map['student_id'] ?? '',
      courseYear: map['course_year'] ?? '',
      email:      map['email'] ?? '',
      avatarUrl:  map['avatar_url'],
    );
  }

  String get initials {
    final parts = fullName.trim().split(' ');
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';
  }
}