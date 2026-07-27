@echo off
rem chandler — 开发期入口 wrapper(Windows;POSIX 侧见同目录的 `chandler`)。
rem 定位仓库根(bin\..),加进库搜索路径,跑 CLI 程序。
rem
rem **仅用于:开发 chandler 自身 / 快速从源码跑 CLI。** 与 sh 版同样的告诫:
rem 它从**平铺的仓库**加载 chandler(非 src/mt 前缀),故与 CHANDLER_HOME
rem (装好的前缀)不是同一份对象。构建**依赖 chandler 的 app** 时别用它 ——
rem 进程内编译会把 app 链到本进程已加载的 chandler 实例,与 CHANDLER_HOME 的
rem 磁盘对象 UID 不符,打出的包一启动就报「different compilation instance」。
rem 那种情形用**装好的 chandler**,或 `scheme --script bootstrap.ss --bootstrap-only`
rem 后的 `_bootstrap\bin\chandler.cmd`。
setlocal
set "HERE=%~dp0.."

rem 运行时选择,与生成的启动器同一套(designs/06):CHANDLER_RUNTIME 选"哪一种"
rem (默认 skiff 优先、无 skiff 回退 chez),CHANDLER_SKIFF/CHANDLER_SCHEME 选"哪个 exe"。
rem 显式(skiff|chez)照单执行,找不到即 127。
rem
rem sh 版对非 Chez 候选还做一次 `_prog_ok` 能力探测(挡住只会打印 demo 的早期
rem skiff stub)。这里**刻意不做** —— 那需要把一段 Scheme 源码经 stdin 喂进候选
rem 运行时,在 cmd 里要靠临时文件绕一大圈,而它挡的是一个早已过期的 stub。
rem 差异是有意的,由 launcher-parity 测试显式钉住,不是漏写。
if /i "%CHANDLER_RUNTIME%"=="skiff" goto :rt_skiff
if /i "%CHANDLER_RUNTIME%"=="chez"  goto :rt_chez
if defined CHANDLER_RUNTIME goto :e_badrt

if defined CHANDLER_SKIFF  where "%CHANDLER_SKIFF%"  >nul 2>nul && set "RT=%CHANDLER_SKIFF%"  && goto :run
if defined CHANDLER_SCHEME where "%CHANDLER_SCHEME%" >nul 2>nul && set "RT=%CHANDLER_SCHEME%" && goto :run
where skiff       >nul 2>nul && set "RT=skiff"       && goto :run
where scheme      >nul 2>nul && set "RT=scheme"      && goto :run
where chez        >nul 2>nul && set "RT=chez"        && goto :run
where chez-scheme >nul 2>nul && set "RT=chez-scheme" && goto :run
where chezscheme  >nul 2>nul && set "RT=chezscheme"  && goto :run
goto :e_nort

:rt_skiff
set "RT=%CHANDLER_SKIFF%"
if not defined RT set "RT=skiff"
goto :run

:rt_chez
set "RT=%CHANDLER_SCHEME%"
if not defined RT set "RT=scheme"
goto :run

:run
"%RT%" -q --libdirs "%HERE%" --program "%HERE%\chandler\cli\main.sps" %*
exit /b %errorlevel%

:e_badrt
>&2 echo chandler: invalid CHANDLER_RUNTIME=%CHANDLER_RUNTIME% ^(want: skiff ^| chez^)
exit /b 64
:e_nort
>&2 echo chandler: no Scheme runtime found ^(need skiff or Chez Scheme^)
exit /b 127
