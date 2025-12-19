cmake_minimum_required(VERSION 3.16)
project(libplasma VERSION 1.0.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(BUILD_SHARED_LIBS ON)

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(ECMQmlModule)

find_package(Qt6 REQUIRED COMPONENTS Qml)
find_package(KF6 REQUIRED COMPONENTS I18n)
qt_standard_project_setup()

ecm_add_qml_module(corebindingsplugin URI "org.kde.plasma.core" VERSION 2.0 DEPENDENCIES QtCore QtQuick org.kde.config)
target_link_libraries(corebindingsplugin PRIVATE KF6::I18n KF6I18nQml)
target_sources(corebindingsplugin PRIVATE corebindingsplugin.cpp)

ecm_target_qml_sources(corebindingsplugin SOURCES Window.qml Theme.qml force-plugin)
ecm_finalize_qml_module(corebindingsplugin DESTINATION ${KDE_INSTALL_QMLDIR})