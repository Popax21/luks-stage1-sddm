#include <KLocalizedQmlContext>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExtensionPlugin>

class CoreBindingsPlugin : public QQmlExtensionPlugin {
  Q_OBJECT
  Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QQmlExtensionInterface")

public:
  void initializeEngine(QQmlEngine *engine, const char *uri) override {
    QQmlExtensionPlugin::initializeEngine(engine, uri);

    // initialize localization (the only thing we care about)
    QQmlContext *context = engine->rootContext();
    if (!context->contextObject()) {
      context->setContextObject(new KLocalizedQmlContext(engine));
    }
  }

  void registerTypes(const char *uri) override {}
};

#include "corebindingsplugin.moc"