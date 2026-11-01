# Malaria Care notification appearance patch

Upstream: flutter_local_notifications 22.3.3, MIT license retained in LICENSE.

The only upstream Java change calls CareNotificationAppearance after constructing a notification. The added helper supplies app-owned RemoteViews with rounded, touch-sized buttons for dose_reminder_v2 / previous_dose_v2 channels. PendingIntents, channel configuration, alarm scheduling, boot restore, payloads and background callback dispatch remain those produced by upstream. Other channels or missing app layouts use the original notification. App resources are kept explicitly for release shrinking. Dart and Apple source is unmodified upstream source.

Android 12+ retains the system notification header and outer template; only the content and buttons are customized. See https://developer.android.com/develop/ui/views/notifications/custom-notification .
