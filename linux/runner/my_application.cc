#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <gdk-pixbuf/gdk-pixbuf.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter/generated_plugin_registrant.h"

// desktop_multi_window 子窗口（桌面歌词悬浮窗）引擎默认只注册该插件自身
// （包源码 linux/flutter_window.cc：internal 注册 + WindowChannel(id)，
// 后者把子引擎 "mixin.one/flutter_multi_window_channel" 的原生处理器绑定为
// 子窗自身）。与 Windows runner（windows/runner/main.cpp 的
// DesktopMultiWindowSetWindowCreatedCallback）同构：回调里禁止
// fl_register_plugins 全量注册——重复注册 DesktopMultiWindowPlugin 会在
// 已 Attach 主窗时再走一遍主窗注册路径，早退无害，但过程对象析构可能
// 触碰共享单例状态；这里只补注册悬浮窗必需的 window_manager（隐藏
// 标题栏/置顶/跳过任务栏/防关闭等）。shared_preferences_linux 为纯
// Dart 插件，无需原生注册。
static void register_subwindow_plugins(FlPluginRegistry* registry) {
  auto* registrar = fl_plugin_registry_get_registrar_for_plugin(
      registry, "WindowManagerPlugin");
  window_manager_plugin_register_with_registrar(registrar);
}

// Loads the application window icon from the installed PNG resources. Returns
// nullptr if the file cannot be read; callers should fall back gracefully.
static GdkPixbuf* load_app_icon(int size) {
  gchar* path = g_strdup_printf("%s/app_icon_%d.png", APP_ICON_DIR, size);
  GError* error = nullptr;
  GdkPixbuf* pixbuf = gdk_pixbuf_new_from_file(path, &error);
  if (error) {
    g_warning("Failed to load app icon %s: %s", path, error->message);
    g_error_free(error);
  }
  g_free(path);
  return pixbuf;
}

// Sets the window icon from the largest available bundled PNG.
static void set_window_icon(GtkWindow* window) {
  const int kSizes[] = {256, 128, 64, 32, 16};
  GdkPixbuf* pixbuf = nullptr;
  for (size_t i = 0; i < G_N_ELEMENTS(kSizes) && pixbuf == nullptr; i++) {
    pixbuf = load_app_icon(kSizes[i]);
  }
  if (pixbuf) {
    gtk_window_set_icon(window, pixbuf);
    g_object_unref(pixbuf);
  }
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Set the window icon from bundled PNG resources.
  set_window_icon(window);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "时音");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "时音");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  // 子窗引擎创建时（desktop_multi_window 创建歌词悬浮窗）回调注册
  // window_manager。必须在任何 createWindow 之前设置——activate 是
  // 主窗唯一入口，主窗生命周期内子窗只会晚于此创建。
  desktop_multi_window_plugin_set_window_created_callback(
      register_subwindow_plugins);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
