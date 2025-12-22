@echo off
setlocal
set DIRNAME=%~dp0
set APP_BASE_NAME=%~nx0

if not defined JAVA_HOME goto findJavaFromPath
set JAVA_EXE=%JAVA_HOME%\bin\java.exe
if exist "%JAVA_EXE%" goto ok

:findJavaFromPath
set JAVA_EXE=java.exe

:ok
"%JAVA_EXE%" -classpath "%DIRNAME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
