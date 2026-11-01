package com.dexterous.flutterlocalnotifications;

import android.app.Notification;
import android.content.Context;
import android.os.Build;
import android.view.View;
import android.widget.RemoteViews;

/** App-specific layout only; preserve upstream scheduling and action PendingIntents. */
final class CareNotificationAppearance {
  private CareNotificationAppearance() {}
  private static int resource(Context context, String type, String name) {
    return context.getResources().getIdentifier(name, type, context.getPackageName());
  }
  static Notification decorate(Context context, Notification original, String channel) {
    if (Build.VERSION.SDK_INT < 24 || channel == null ||
        !(channel.startsWith("dose_reminder_v2") || channel.startsWith("previous_dose_v2")) ||
        original.actions == null || original.actions.length == 0) return original;
    int small = resource(context, "layout", "care_notification_small");
    int big = resource(context, "layout", "care_notification_big");
    if (small == 0 || big == 0) return original;
    try {
      Notification.Action[] actions = original.actions;
      RemoteViews compact = new RemoteViews(context.getPackageName(), small);
      RemoteViews expanded = new RemoteViews(context.getPackageName(), big);
      bind(context, compact, actions);
      bind(context, expanded, actions);
      compact.setTextViewText(resource(context,"id","care_summary"),
          channel.startsWith("previous_dose_v2") ? "前日の服用確認" : "飲む時間です。");
      expanded.setTextViewText(resource(context,"id","care_title"), original.extras.getCharSequence(Notification.EXTRA_TITLE));
      expanded.setTextViewText(resource(context,"id","care_body"), original.extras.getCharSequence(Notification.EXTRA_TEXT));
      // Recovering a builder may retain the source action array even after setActions(empty).
      // Clear the clone before recovery so the system template cannot draw a second action row.
      Notification base = original.clone();
      base.actions = new Notification.Action[0];
      base.contentView = null;
      base.bigContentView = null;
      base.headsUpContentView = null;
      Notification result = Notification.Builder.recoverBuilder(context, base)
          .setStyle(new Notification.DecoratedCustomViewStyle())
          .setCustomContentView(compact).setCustomBigContentView(expanded)
          .setCustomHeadsUpContentView(compact)
          // The custom buttons already contain these exact background PendingIntents.
          .setActions(new Notification.Action[0]).build();
      result.actions = new Notification.Action[0];
      result.flags |= original.flags;
      result.extras.putBoolean("care_buttons_v1", true);
      result.extras.putInt("care_button_count", actions.length);
      return result;
    } catch (RuntimeException error) {
      // A resource mismatch must never prevent delivery of the original notification.
      android.util.Log.w("MalariaCare", "Using standard notification layout", error);
      return original;
    }
  }
  private static void bind(Context context, RemoteViews view, Notification.Action[] actions) {
    int primary = resource(context,"id","care_primary");
    int secondary = resource(context,"id","care_secondary");
    view.setTextViewText(primary, actions[0].title);
    view.setContentDescription(primary, actions[0].title);
    view.setOnClickPendingIntent(primary, actions[0].actionIntent);
    if (actions.length > 1) {
      view.setTextViewText(secondary, actions[1].title);
      view.setContentDescription(secondary, actions[1].title);
      view.setOnClickPendingIntent(secondary, actions[1].actionIntent);
      view.setViewVisibility(secondary, View.VISIBLE);
    } else {
      view.setViewVisibility(secondary, View.GONE);
    }
  }
}
