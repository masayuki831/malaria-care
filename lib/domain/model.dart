import 'dart:convert';

DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime plusDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
int daysBetween(DateTime a, DateTime b) => DateTime.utc(
  b.year,
  b.month,
  b.day,
).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
String newId() => DateTime.now().microsecondsSinceEpoch.toString();

enum DoseStatus { planned, assumed, confirmed, missed, stockout }

extension StatusLabel on DoseStatus {
  String get label => ['予定', '服用済み', '服用済み', '飲み忘れ', '在庫不足'][index];
}

enum Frequency { daily, days, weekdays, weeks }

class Rule {
  final Frequency frequency;
  final int interval, hour, minute;
  final List<int> weekdays;
  final DateTime anchor;
  final bool usesWeekday;
  Rule({
    required this.frequency,
    required this.anchor,
    this.interval = 1,
    this.hour = 20,
    this.minute = 0,
    this.weekdays = const [1],
    this.usesWeekday = false,
  });
  bool matches(DateTime date) {
    final delta = daysBetween(anchor, date);
    if (delta < 0) return false;
    return switch (frequency) {
      Frequency.daily => true,
      Frequency.days => delta % interval == 0,
      Frequency.weekdays => weekdays.contains(date.weekday),
      Frequency.weeks =>
        usesWeekday
            ? delta >= (weekdays.first - anchor.weekday + 7) % 7 &&
                  (delta - (weekdays.first - anchor.weekday + 7) % 7) %
                          (interval * 7) ==
                      0
            : delta % (interval * 7) == 0,
    };
  }

  Rule reanchor(DateTime date) => Rule(
    frequency: frequency,
    anchor: day(date),
    interval: interval,
    hour: hour,
    minute: minute,
    weekdays: [date.weekday],
    usesWeekday: usesWeekday,
  );
  String get label => switch (frequency) {
    Frequency.daily => '毎日',
    Frequency.days => '$interval日ごと',
    Frequency.weekdays =>
      '毎週 ${weekdays.map((d) => '月火水木金土日'[d - 1]).join('・')}曜日',
    Frequency.weeks =>
      '$interval週間ごと・${'月火水木金土日'[(usesWeekday ? weekdays.first : anchor.weekday) - 1]}曜日',
  };
  Map<String, dynamic> toJson() => {
    'frequency': frequency.name,
    'anchor': ymd(anchor),
    'interval': interval,
    'hour': hour,
    'minute': minute,
    'weekdays': weekdays,
    if (usesWeekday) 'usesWeekday': true,
  };
  factory Rule.fromJson(Map<String, dynamic> j) => Rule(
    frequency: Frequency.values.byName(j['frequency']),
    anchor: DateTime.parse(j['anchor']),
    interval: j['interval'],
    hour: j['hour'],
    minute: j['minute'],
    weekdays: List<int>.from(j['weekdays']),
    usesWeekday: j['usesWeekday'] == true,
  );
}

class ScheduleVersion {
  final DateTime effective;
  final Rule rule;
  final double dose;
  final String reason;
  ScheduleVersion(this.effective, this.rule, this.dose, [this.reason = '']);
  Map<String, dynamic> toJson() => {
    'effective': ymd(effective),
    'rule': rule.toJson(),
    'dose': dose,
    'reason': reason,
  };
  factory ScheduleVersion.fromJson(Map<String, dynamic> j) => ScheduleVersion(
    DateTime.parse(j['effective']),
    Rule.fromJson(j['rule']),
    (j['dose'] as num).toDouble(),
    j['reason'],
  );
}

class Medicine {
  final String id;
  String name, memo;
  DateTime start;
  DateTime? end;
  double initial;
  bool reminder;
  List<ScheduleVersion> versions;
  Medicine({
    required this.id,
    required this.name,
    required this.start,
    required this.initial,
    required this.versions,
    this.end,
    this.memo = '',
    this.reminder = true,
  });
  ScheduleVersion versionAt(DateTime date) =>
      versions.lastWhere((v) => !v.effective.isAfter(day(date)));
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'start': ymd(start),
    'end': end == null ? null : ymd(end!),
    'initial': initial,
    'memo': memo,
    'reminder': reminder,
    'versions': versions.map((e) => e.toJson()).toList(),
  };
  factory Medicine.fromJson(Map<String, dynamic> j) => Medicine(
    id: j['id'],
    name: j['name'],
    start: DateTime.parse(j['start']),
    end: j['end'] == null ? null : DateTime.parse(j['end']),
    initial: (j['initial'] as num).toDouble(),
    memo: j['memo'],
    reminder: j['reminder'],
    versions: (j['versions'] as List)
        .map((e) => ScheduleVersion.fromJson(e))
        .toList(),
  );
}

class Dose {
  final String id, medicineId, name;
  final DateTime scheduled;
  final double quantity;
  DoseStatus? explicit;
  DateTime? actual, confirmedAt;
  bool later;
  String note;
  Dose({
    required this.id,
    required this.medicineId,
    required this.name,
    required this.scheduled,
    required this.quantity,
    this.explicit,
    this.actual,
    this.confirmedAt,
    this.later = false,
    this.note = '',
  });
  DoseStatus status(DateTime now) => day(scheduled).isAfter(day(now))
      ? DoseStatus.planned
      : explicit ?? DoseStatus.assumed;
  bool get delayed => actual != null && day(actual!) != day(scheduled);
  DateTime? consumptionAt(DateTime now) => switch (status(now)) {
    DoseStatus.assumed => scheduled,
    DoseStatus.confirmed => actual ?? scheduled,
    _ => null,
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'medicineId': medicineId,
    'name': name,
    'scheduled': scheduled.toIso8601String(),
    'quantity': quantity,
    'explicit': explicit?.name,
    'actual': actual?.toIso8601String(),
    'confirmedAt': confirmedAt?.toIso8601String(),
    'later': later,
    'note': note,
  };
  factory Dose.fromJson(Map<String, dynamic> j) => Dose(
    id: j['id'],
    medicineId: j['medicineId'],
    name: j['name'],
    scheduled: DateTime.parse(j['scheduled']),
    quantity: (j['quantity'] as num).toDouble(),
    explicit: j['explicit'] == null
        ? null
        : DoseStatus.values.byName(j['explicit']),
    actual: j['actual'] == null ? null : DateTime.parse(j['actual']),
    confirmedAt: j['confirmedAt'] == null
        ? null
        : DateTime.parse(j['confirmedAt']),
    later: j['later'],
    note: j['note'],
  );
}

class Refill {
  final String id, medicineId, note;
  final DateTime date;
  final double quantity;
  Refill(this.id, this.medicineId, this.date, this.quantity, this.note);
  Map<String, dynamic> toJson() => {
    'id': id,
    'medicineId': medicineId,
    'date': ymd(date),
    'quantity': quantity,
    'note': note,
  };
  factory Refill.fromJson(Map<String, dynamic> j) => Refill(
    j['id'],
    j['medicineId'],
    DateTime.parse(j['date']),
    (j['quantity'] as num).toDouble(),
    j['note'],
  );
}

class AppData {
  Map<String, String> profile, mail;
  List<Medicine> medicines;
  List<Dose> doses;
  List<Refill> refills;
  List<Refill> losses;
  bool nextDay;
  int checkHour, checkMinute;
  bool remindersEnabled;
  int reminderHour, reminderMinute;
  bool reminderSound, reminderVibration, checkSound, checkVibration;
  List<String> reminderAcknowledgements;
  AppData({
    required this.profile,
    required this.mail,
    required this.medicines,
    List<Dose>? doses,
    List<Refill>? refills,
    List<Refill>? losses,
    this.nextDay = false,
    this.reminderSound = true,
    this.reminderVibration = true,
    this.checkSound = true,
    this.checkVibration = true,
    List<String>? reminderAcknowledgements,
    this.remindersEnabled = false,
    this.reminderHour = 20,
    this.reminderMinute = 0,
    this.checkHour = 8,
    this.checkMinute = 0,
  }) : reminderAcknowledgements = reminderAcknowledgements ?? [],
       doses = doses ?? [],
       refills = refills ?? [],
       losses = losses ?? [];
  Map<String, dynamic> toJson() => {
    'schemaVersion': 3,
    'reminderSound': reminderSound,
    'reminderVibration': reminderVibration,
    'checkSound': checkSound,
    'checkVibration': checkVibration,
    'reminderAcknowledgements': reminderAcknowledgements,
    'remindersEnabled': remindersEnabled,
    'reminderHour': reminderHour,
    'reminderMinute': reminderMinute,
    'profile': profile,
    'mail': mail,
    'medicines': medicines.map((e) => e.toJson()).toList(),
    'doses': doses.map((e) => e.toJson()).toList(),
    'refills': refills.map((e) => e.toJson()).toList(),
    'losses': losses.map((e) => e.toJson()).toList(),
    'nextDay': nextDay,
    'checkHour': checkHour,
    'checkMinute': checkMinute,
  };
  String export() => const JsonEncoder.withIndent('  ').convert(toJson());
  factory AppData.parse(String source) {
    if (source.length > 20 * 1024 * 1024)
      throw const FormatException('ファイルが大きすぎます（上限20MB）。');
    try {
      final j = jsonDecode(source) as Map<String, dynamic>;
      if (![1, 2, 3].contains(j['schemaVersion']))
        throw const FormatException('未対応のデータ形式です。');
      final data = AppData(
        reminderSound: j['reminderSound'] as bool? ?? true,
        reminderVibration: j['reminderVibration'] as bool? ?? true,
        checkSound: j['checkSound'] as bool? ?? true,
        checkVibration: j['checkVibration'] as bool? ?? true,
        reminderAcknowledgements: List<String>.from(
          j['reminderAcknowledgements'] ?? [],
        ),
        profile: Map<String, String>.from(j['profile']),
        mail: Map<String, String>.from(j['mail']),
        medicines: (j['medicines'] as List)
            .map((e) => Medicine.fromJson(e))
            .toList(),
        doses: (j['doses'] as List).map((e) => Dose.fromJson(e)).toList(),
        refills: (j['refills'] as List).map((e) => Refill.fromJson(e)).toList(),
        losses: (j['schemaVersion'] == 1 ? <dynamic>[] : j['losses'] as List)
            .map((e) => Refill.fromJson(e))
            .toList(),
        nextDay: j['schemaVersion'] == 3 && j['nextDay'] == true,
        remindersEnabled: j['schemaVersion'] == 3
            ? j['remindersEnabled']
            : (j['medicines'] as List).any((m) => m['reminder'] == true),
        reminderHour: j['schemaVersion'] == 3
            ? j['reminderHour']
            : ((j['medicines'] as List).isEmpty
                  ? 20
                  : j['medicines'][0]['versions'].last['rule']['hour']),
        reminderMinute: j['schemaVersion'] == 3
            ? j['reminderMinute']
            : ((j['medicines'] as List).isEmpty
                  ? 0
                  : j['medicines'][0]['versions'].last['rule']['minute']),
        checkHour: j['checkHour'],
        checkMinute: j['checkMinute'],
      );
      data.validate();
      return data;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('必須項目または型が不正です。');
    }
  }
  void validate() {
    void require(bool ok) {
      if (!ok) throw const FormatException('データの整合性を確認できません。');
    }

    require(
      reminderHour >= 0 &&
          reminderHour < 24 &&
          reminderMinute >= 0 &&
          reminderMinute < 60 &&
          checkHour >= 0 &&
          checkHour < 24 &&
          checkMinute >= 0 &&
          checkMinute < 60,
    );
    for (final key in ['name', 'cohort', 'job', 'location', 'start', 'end']) {
      require(profile.containsKey(key));
    }
    require(
      DateTime.tryParse(profile['start']!) != null &&
          DateTime.tryParse(profile['end']!) != null,
    );
    require(
      !DateTime.parse(profile['end']!)
          .isBefore(DateTime.parse(profile['start']!)),
    );
    for (final key in ['to', 'subject', 'body', 'signature']) {
      require(mail.containsKey(key));
    }
    final ids = medicines.map((m) => m.id).toSet();
    require(ids.length == medicines.length && medicines.length <= 100);
    for (final m in medicines) {
      require(
        m.id.isNotEmpty &&
            m.name.trim().isNotEmpty &&
            m.name.length <= 200 &&
            m.initial.isFinite &&
            m.initial >= 0,
      );
      require(m.end == null || !m.end!.isBefore(m.start));
      require(
        m.versions.isNotEmpty && !m.versions.first.effective.isAfter(m.start),
      );
      DateTime? previous;
      for (final v in m.versions) {
        require(
          v.dose.isFinite &&
              v.dose > 0 &&
              (previous == null || v.effective.isAfter(previous)),
        );
        require(
          v.rule.interval > 0 &&
              v.rule.interval <= 3650 &&
              v.rule.hour >= 0 &&
              v.rule.hour < 24 &&
              v.rule.minute >= 0 &&
              v.rule.minute < 60,
        );
        require(
          v.rule.weekdays.isNotEmpty &&
              v.rule.weekdays.every((d) => d >= 1 && d <= 7),
        );
        require(!v.rule.usesWeekday || v.rule.weekdays.length == 1);
        require(!v.rule.anchor.isAfter(v.effective));
        previous = v.effective;
      }
    }
    require(
      reminderAcknowledgements.length ==
              reminderAcknowledgements.toSet().length &&
          reminderAcknowledgements.every(
            (id) => id.startsWith('reminder:') && id.length <= 250,
          ),
    );
    require(doses.map((d) => d.id).toSet().length == doses.length);
    for (final d in doses) {
      require(
        ids.contains(d.medicineId) && d.quantity.isFinite && d.quantity > 0,
      );
      require(d.id == '${d.medicineId}@${ymd(d.scheduled)}');
      require(d.note.length <= 200);
      final m = medicines.firstWhere((m) => m.id == d.medicineId);
      require(!d.scheduled.isBefore(m.start));
      final v = m.versionAt(d.scheduled);
      require(
        v.rule.matches(d.scheduled) &&
            d.scheduled.hour == v.rule.hour &&
            d.scheduled.minute == v.rule.minute &&
            d.quantity == v.dose,
      );
      require(
        d.explicit != DoseStatus.planned &&
            d.explicit != DoseStatus.stockout &&
            (d.explicit == DoseStatus.confirmed) == (d.actual != null),
      );
      require(d.explicit != DoseStatus.confirmed || d.confirmedAt != null);
      require(d.actual == null || !d.actual!.isAfter(d.confirmedAt!));
      require(
        d.actual == null ||
            !d.actual!.isBefore(
              medicines.firstWhere((m) => m.id == d.medicineId).start,
            ),
      );
    }
    final inventory = [...refills, ...losses];
    require(inventory.map((r) => r.id).toSet().length == inventory.length);
    for (final r in inventory) {
      require(
        ids.contains(r.medicineId) && r.quantity.isFinite && r.quantity > 0,
      );
      require(
        !r.date.isBefore(
          medicines.firstWhere((m) => m.id == r.medicineId).start,
        ),
      );
    }
  }

  Medicine? medicineAt(DateTime date) => medicines
      .where(
        (m) =>
            !day(m.start).isAfter(day(date)) &&
            (m.end == null || !day(m.end!).isBefore(day(date))),
      )
      .firstOrNull;
  bool overlaps(Medicine candidate) => medicines.any(
    (m) =>
        m.id != candidate.id &&
        !(m.end != null && day(m.end!).isBefore(day(candidate.start))) &&
        !(candidate.end != null && day(candidate.end!).isBefore(day(m.start))),
  );
  bool get hasOverlappingMedicines => medicines.any(overlaps);

  factory AppData.empty() => AppData(
    profile: {
      'name': '',
      'cohort': '',
      'job': '',
      'location': '',
      'start': ymd(DateTime.now()),
      'end': ymd(plusDays(DateTime.now(), 730)),
    },
    mail: {
      'to': '',
      'subject': 'マラリア予防薬服薬状況報告（{氏名}）',
      'body': 'ご担当者様\n\nマラリア予防薬の服薬状況について報告します。\n\n氏名：{氏名}\n隊次：{隊次}\n使用予防薬名：{薬名}\n報告対象期間：{期間}\n\n{残数}\n\n詳細は添付PDFをご確認ください。\nよろしくお願いいたします。',
      'signature': '',
    },
    medicines: [],
  );
}
