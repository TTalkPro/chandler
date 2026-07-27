#!chezscheme
;;; chandler/fs.ss --- 文件系统操作(优先 Chez 原生,替代 shell-out)
;;;
;;; 消除 fetch/install/registry 各写一份 ensure-dir/rm-rf/dir-entries 的冗余。
;;; 用 Chez 原生 directory-list/rename-file/delete-directory/bytevector I/O,不 shell-out
;;; (更快、可移植、无引用注入面)。

(library (chandler fs)
  (export parent-dir base-name path-join* absolute-path?
           path-sep-char? has-path-sep?
           ensure-dir ensure-parent
           dir-entries files-under dir-empty?
           rm-rf copy-file move-file
           read-file-string read-lines write-text write-text-atomic write-text-crlf
           call-with-text-input-file call-with-text-output-file
           sweep-empty-parents home-dir
           write-text-if-changed file-byte-size mtime
           path-swap-ext normalize-seps path-segments
           parent-dir-or-dot system-temp-dir
           path-has-segment? unmanaged-path-segments unmanaged-path?
           relativize rel-files-under)
  (import (chezscheme)
          (chandler util))

  ;; ══════════════════════════════════════════════════════════════════
  ;; 路径分隔符(D36)
  ;;
  ;; POSIX 只有 `/`;Windows 上 `\` 与 `/` **都是**(Chez 两者都接受、内部规范化),
  ;; 而 Chez 自己的 API(`current-directory`、`library-object-filename`、
  ;; `directory-list`)在 Windows 上返回的是**反斜杠**形。
  ;;
  ;; 于是「只认 `/`」的路径原语在 Windows 上不会崩,只会**悄悄给出错误答案**:
  ;;   • `base-name "C:\proj\foo.ss"` 返回整串
  ;;   • `path-has-segment?` 认不出 `_build` / `.git` 段 → `unmanaged-path?` 恒假
  ;;     → **install 清单与 `chandler verify` 把生成物和 `.git` 当成受管文件**
  ;;   • `relativize` 的裸前缀匹配失败 → 相对路径变成绝对路径
  ;; 全是静默的,比崩溃危险。
  ;;
  ;; 单一出处在此:下面每个原语都走 path-sep-char?,不各写各的。
  ;; ══════════════════════════════════════════════════════════════════
  (define (path-sep-char? c) (or (char=? c #\/) (char=? c #\\)))

  (define (has-path-sep? s)
    (let loop ([i (- (string-length s) 1)])
      (cond [(< i 0) #f]
            [(path-sep-char? (string-ref s i)) #t]
            [else (loop (- i 1))])))

  ;; 分隔符归一到 `/`。**用于会被记录下来或跨平台比较的相对路径** ——
  ;; lock 的 `(files …)`、install/pack 的清单键都是字符串比对,一边写
  ;; `_vendor/greet/greet.ss`、另一边写 `_vendor\greet\greet.ss` 的话,
  ;; 同一棵树在两个平台上算出来的清单就对不上。Chez 在 Windows 上照吃 `/`,
  ;; 故归一后依然可直接用来开文件。
  (define (normalize-seps s)
    (if (has-path-sep? s)
        (list->string (map (lambda (c) (if (path-sep-char? c) #\/ c)) (string->list s)))
        s))

  ;; 按任一分隔符切段(空段丢弃,故 "a//b" 与 "a/b" 同)
  (define (path-segments p)
    (let ([n (string-length p)])
      (let loop ([i 0] [start 0] [acc '()])
        (cond
          [(= i n) (reverse (if (> i start) (cons (substring p start i) acc) acc))]
          [(path-sep-char? (string-ref p i))
           (loop (+ i 1) (+ i 1)
                 (if (> i start) (cons (substring p start i) acc) acc))]
          [else (loop (+ i 1) start acc)]))))

  ;; ── 路径拆分(纯字符串;拼接见 (chandler layout))──
  (define (parent-dir path)
    (let ([i (last-slash path)])
      (cond
        [(< i 0) ""]
        [(= i 0) "/"]
        ;; "C:/foo" → 父目录是 C: 盘的**根**("C:/"),不是 "C:"(那是盘上的
        ;; 「当前目录」,drive-relative,含义完全不同)。少这一条时 ensure-dir
        ;; 会往 drive-relative 路径上递归。
        [(drive-prefix? path i) (substring path 0 (+ i 1))]
        [else (substring path 0 i)])))

  ;; path 的 [0,i) 是不是恰好一个盘符前缀("C:")
  (define (drive-prefix? path i)
    (and (= i 2)
         (char=? #\: (string-ref path 1))
         (char-alphabetic? (string-ref path 0))))

  (define (base-name path)
    (let ([i (last-slash path)])
      (if (< i 0) path (substring path (+ i 1) (string-length path)))))

  ;; 最后一个分隔符的下标(`/` 或 `\`);没有则 -1
  (define (last-slash path)
    (let loop ([i (- (string-length path) 1)])
      (cond [(< i 0) -1]
            [(path-sep-char? (string-ref path i)) i]
            [else (loop (- i 1))])))

  ;; 拼接:a 已以分隔符收尾(两种都算)就不再补,否则补 `/`
  (define (path-join* a b)
    (cond [(string=? a "") b]
          [(path-sep-char? (string-ref a (- (string-length a) 1))) (string-append a b)]
          [else (string-append a "/" b)]))

  ;; 路径是否绝对:POSIX 的前导 `/`(或 Windows 的前导 `\`),或盘符形 `C:\` / `C:/`。
  ;;
  ;; **盘符那条要收紧到「字母 + `:` + 分隔符」**:先前只要第二个字符是 `:` 就算绝对,
  ;; 于是 POSIX 上一个叫 `a:b` 的相对路径被误判成绝对路径,`abspath` 就不会把它
  ;; 接到项目根上。而 Windows 的 `C:foo`(drive-relative,意思是「C 盘当前目录下的
  ;; foo」)本来也**不是**绝对路径 —— runtime-paths 的资源校验正是要拒它。
  ;;
  ;; 全仓单一出处 —— 先前 manifest / commands(两处)/ runtime-env / runtime-paths /
  ;; native-build 各写一份,其中只有 manifest 那份认盘符,其余在 Windows 上会把
  ;; "C:\proj" 当相对路径去拼接。
  (define (absolute-path? p)
    (and (string? p) (> (string-length p) 0)
         (or (path-sep-char? (string-ref p 0))
             (and (> (string-length p) 2)
                  (char-alphabetic? (string-ref p 0))
                  (char=? #\: (string-ref p 1))
                  (path-sep-char? (string-ref p 2))))))

  ;; ── 目录创建(递归,幂等)──
  (define (ensure-dir dir)
    (unless (or (string=? dir "") (string=? dir "/") (file-directory? dir))
      (ensure-dir (parent-dir dir))
      (ignore-errors (mkdir dir))))            ; 并发/竞态下已存在即忽略

  (define (ensure-parent path) (ensure-dir (parent-dir path)))

  ;; ── 目录枚举(原生 directory-list;不含 . ..)──
  ;; 读不动(权限等)→ '():ignore-errors 给回 #f,直接喂 sort 会当场抛,
  ;; 于是一个不可读的子目录能让整趟 files-under 崩掉。
  (define (dir-entries dir)
    (if (file-directory? dir)
        (sort string<? (or (ignore-errors (directory-list dir)) '()))
        '()))

  (define (dir-empty? dir) (null? (dir-entries dir)))

  ;; 递归列出目录下所有普通文件(绝对路径),深度优先、字典序。
  ;;
  ;; **单向累积,不用 append**:原实现是 (append acc (files-under full)),每遇到一个
  ;; 子目录就把已累积的表整份复制一遍 —— 对文件数是平方级。而本函数是全仓最热的 FS
  ;; 原语(pack 清单、verify、enumerate-lib、copy-tree!、native 扫描全走它),前缀一大
  ;; 就很痛。改成把结果 cons 进同一个累积器、最后一次 reverse:线性,且顺序变得确定
  ;; (先前是「同级文件逆序、子目录结果追加在后」的混合序,调用方普遍还得再 list-sort)。
  (define (files-under dir)
    (reverse (files-under/acc dir '())))

  (define (files-under/acc dir acc)
    (fold-left
      (lambda (acc name)
        (let ([full (path-join* dir name)])
          (if (file-directory? full)
              (files-under/acc full acc)
              (cons full acc))))
      acc (dir-entries dir)))

  ;; ── 删除(原生递归)──
  ;; rm-rf:尽力删,**但不假装成功**。
  ;;
  ;; 先前每一步都套 ignore-errors,于是 Windows 上两类常见失败被完全吞掉:
  ;;   ① git 的 `.git/objects/**` 是**只读**的 → delete-file 失败
  ;;   ② 已 load-shared-object 的 DLL、运行中的 exe **不能删也不能改名**
  ;; 调用方(镜像缓存清理、staging 清理、pack 的 commit)于是以为清干净了,
  ;; 而磁盘上留着残件 —— 下一次操作撞上它,报的错离现场很远。
  ;;
  ;; 现在:只读文件先清只读位再重试一次(Windows 上这就够了);仍失败则
  ;; **抛**,并把最可能的原因说出来。rm-rf 的幂等语义不变(目标不存在 = 成功)。
  (define (rm-rf path)
    (cond
      [(not (or (file-exists? path) (file-directory? path))) (void)]
      [(file-directory? path)
       (for-each (lambda (e) (rm-rf (path-join* path e))) (dir-entries path))
       (delete-with-retry path delete-directory "directory")]
      [else (delete-with-retry path delete-file "file")]))

  ;; 删不掉 → 清只读位重试 → 还不行就抛(带可操作诊断)。
  ;;
  ;; **Chez 的 `delete-file` / `delete-directory` 失败时返回 `#f`,不抛**
  ;; (要抛得传 `error?` 第二参)。所以先前那圈 `ignore-errors` 其实什么也没接住 ——
  ;; 静默不是它造成的,是这条默认语义造成的,而 `ignore-errors` 让代码**看起来**
  ;; 已经考虑过失败了。这里直接判返回值。
  (define (delete-with-retry path del what)
    (unless (del path)
      (ignore-errors (clear-read-only! path))
      (unless (del path)
        (error 'rm-rf
               (format "cannot remove ~a: ~a~%  (it may be read-only, or in use by another process -- on Windows a loaded .dll or a running .exe can be neither deleted nor renamed)"
                       what path)))))

  ;; 清只读位。**用 Chez 自带的 `chmod`,不 shell-out** —— fs 是最底层库,
  ;; 不能 import proc(proc 依赖 fs,会成环),而在这里手拼一条 `system` 命令
  ;; 就等于把 B4 修掉的那种「自己写一份引用」重新引进来,还是在最底层。
  ;;
  ;; Windows 上 Chez 的 chmod 只认「写位」(对应只读属性),正是这里要清的那一位。
  ;; 失败无所谓:外层还会再试一次删除,仍不行才抛。
  (define (clear-read-only! path)
    (chmod path (bitwise-ior (get-mode path) #o200)))

  ;; 删除因某文件消失而变空的祖先目录链
  (define (sweep-empty-parents path)
    (let loop ([d (parent-dir path)])
      (when (and (> (string-length d) 1) (file-directory? d) (dir-empty? d))
        (ignore-errors (delete-directory d))
        (loop (parent-dir d)))))

  ;; ── 拷贝/移动(原生 bytevector / rename-file)──
  (define (copy-file src dst)
    (ensure-parent dst)
    (let ([bytes (call-with-port (open-file-input-port src) get-bytevector-all)])
      (call-with-port (open-file-output-port dst (file-options no-fail))
        (lambda (p) (unless (eof-object? bytes) (put-bytevector p bytes))))))

  ;; 移动。**目标已存在时先删** —— Windows 的 rename 不覆盖既有目标。
  ;; `sexp.ss` 的 write-canonical-file、`pack/core.ss` 的 commit-pack-output!、
  ;; `registry/staging.ss` 的 promote-staging! 都各自处理过这件事,唯独这个
  ;; 共用的搬运函数没有;它唯一的调用点 `compile.ss` 的 touch-file! 还套着
  ;; ignore-errors,于是 Windows 上 touch **静默失效**,mtime 不更新,
  ;; 增量构建的判断跟着退化。
  (define (move-file src dst)
    (ensure-parent dst)
    (when (file-exists? dst)
      (guard (e (#t (void))) (delete-file dst)))
    (rename-file src dst))

  ;; ══════════════════════════════════════════════════════════════════
  ;; 文本 I/O(D38:字节行为与平台无关)
  ;;
  ;; **不用默认 transcoder**。R6RS 的 `(make-transcoder codec)` 取
  ;; `(native-eol-style)`,那是平台相关的:本机(Linux/Chez 10.4.1)实测为 `none`,
  ;; 但若某平台是 `crlf`,`call-with-output-file` 就会把 `\n` 写成 `\r\n` ——
  ;; 于是**同一个 datum 在两个平台上写出不同的字节**。
  ;;
  ;; 那正好是致命的:lock 的 `manifest-sha256` 与 install/pack 的 per-file sha256
  ;; 都是**字节**指纹(`sha256-file` 走二进制端口读原始字节,且刻意不做归一化 ——
  ;; 归一化会让它不再是「文件真实内容的指纹」,`chandler verify` 就失去意义)。
  ;; 写侧一旦随平台漂移,跨平台协作时 `lock-fresh?` 恒判 stale、`verify` 恒报
  ;; 文件被改,而两边的文件「看起来」完全一样。
  ;;
  ;; 故显式钉死 `none`:chandler 写什么字符就是什么字节。需要 CRLF 的地方
  ;; (`.cmd` 启动器)由 `write-text-crlf` **显式**写 `\r\n`,不靠 transcoder 变魔术。
  ;; 读侧用同一个 transcoder,好让 `write-text-if-changed` 的比较对称。
  ;;
  ;; 配套的另一半在仓库根的 `.gitattributes`:钉住 git checkout 时不改写字节
  ;; (Windows 上 `core.autocrlf=true` 是默认行为)。两边都堵才管用 —— 只堵一边
  ;; 等于没堵。
  ;; ══════════════════════════════════════════════════════════════════
  (define text-transcoder
    (make-transcoder (utf-8-codec) (eol-style none) (error-handling-mode replace)))

  (define (call-with-text-input-file path proc)
    (call-with-port
      (open-file-input-port path (file-options) (buffer-mode block) text-transcoder)
      proc))

  (define (call-with-text-output-file path proc)
    (call-with-port
      (open-file-output-port path (file-options no-fail) (buffer-mode block) text-transcoder)
      proc))

  (define (read-file-string path)
    (if (file-exists? path)
        (call-with-text-input-file path
          (lambda (p)
            (let ([s (get-string-all p)])
              (if (eof-object? s) "" s))))
        ""))

  ;; eol-style none ⇒ `get-line` 只按 `\n` 断行,CRLF 文件的行尾会留一个 `\r`。
  ;; 这与本机先前的行为一致(默认 transcoder 在此也是 none),调用方
  ;; (`env.ss` 的 dotenv 解析)本就对每行 `string-trim`,而 `\r` 是空白字符。
  (define (read-lines path)
    (if (file-exists? path)
        (call-with-text-input-file path
          (lambda (p)
            (let loop ([acc '()])
              (let ([l (get-line p)])
                (if (eof-object? l) (reverse acc) (loop (cons l acc)))))))
        '()))

  (define (write-text path s)
    (ensure-parent path)
    (call-with-text-output-file path (lambda (p) (put-string p s))))

  ;; ── 原子落盘(D20):temp 文件(与目标**同目录** —— 跨目录 rename 不保证原子)
  ;; → 关端口 → rename 覆盖目标。崩溃只留 .tmp 残件;目标要么是旧内容、要么是
  ;; 完整新内容,绝不半截。
  ;;
  ;; Windows 下 rename 不覆盖既有目标:先删(不存在则静默)。POSIX rename 本身
  ;; 原子覆盖,该分支在 POSIX 下不触发;删除引入的竞态窗口由「先写完整 temp」
  ;; 兜底 —— 崩溃至多回到「目标缺失」,而非半截文件。
  ;;
  ;; 全仓单一出处:先前 sexp.ss 的 write-canonical-file 里内联了一份,registry
  ;; sidecar(D35)需要同样的语义但写的是纯文本而非 s-expr。
  (define (write-text-atomic path s)
    (ensure-parent path)
    (let ([tmp (path-join* (parent-dir path)
                           (string-append "." (base-name path) ".tmp."
                                          (number->string (get-process-id))))])
      (guard (e [else (guard (e2 (#t (void))) (delete-file tmp))
                      (raise e)])
        (call-with-text-output-file tmp (lambda (p) (put-string p s)))
        (when (file-exists? path)
          (guard (e (#t (void))) (delete-file path)))
        (rename-file tmp path))))

  ;; ── 写文本,换行一律 CRLF(Windows `.cmd` 启动器专用)──
  ;;
  ;; cmd.exe 对 LF-only 的批处理**大体**容忍,但标签与 `goto` 会出错 —— 而生成的
  ;; `.cmd` 启动器正是用底部错误标签组织的(designs/14 §8.3)。既然只有一种正确答案,
  ;; 就不留给「大体容忍」去赌。
  ;;
  ;; 已是 CRLF 的不重复转换(幂等),故对混合换行的输入也安全。
  (define (write-text-crlf path s)
    (write-text path (lf->crlf s)))

  (define (lf->crlf s)
    (let ([n (string-length s)] [op (open-output-string)])
      (let loop ([i 0])
        (if (= i n)
            (get-output-string op)
            (let ([c (string-ref s i)])
              (when (and (char=? c #\newline)
                         (or (= i 0) (not (char=? #\return (string-ref s (- i 1))))))
                (write-char #\return op))
              (write-char c op)
              (loop (+ i 1)))))))

  (define (home-dir) (or (getenv "HOME") (getenv "USERPROFILE") "."))

  ;; ── 写文本(内容不变则跳过,避免 bump mtime)──
  (define (write-text-if-changed path s)
    (unless (and (file-exists? path)
                 (string=? s (read-file-string path)))
      (write-text path s)))

  ;; 文件字节数(Chez 无直接 file-length port 方法,用 open-file-input-port)
  (define (file-byte-size f)
    (call-with-port (open-file-input-port f) (lambda (p) (file-length p))))

  ;; 文件修改时间(返回数值,与 bake 的 mtime 兼容)
  (define (mtime path)
    (and (file-exists? path) (file-modification-time path)))

  ;; 替换扩展名:无扩展名时追加 new-ext
  (define (path-swap-ext p new-ext)
    (let ([root (path-root p)])
      (if (string=? root p)
          (string-append p new-ext)
          (string-append root new-ext))))

  ;; parent-dir 但空串返回 "."(compile/import-graph 各写一份的统一出处)
  (define (parent-dir-or-dot path)
    (let ([d (parent-dir path)]) (if (string=? d "") "." d)))

  ;; ── 路径段判定 ──
  ;; 路径里是否含 segs 中的某一段。全仓单一出处:先前 cmd-verify 的
  ;; generated-path?、install 的 vendor-unmanaged-path?(两者逐字节相同)、
  ;; fetch 的 build-tree-path? 各写一份,注释还互相叮嘱「两侧必须一致」——
  ;; 那种不变式该由共用代码保证,不该靠注释。
  ;;
  ;; **按任一分隔符切段**(D36):先前只按 `/` 切,于是 Windows 上
  ;; `C:\proj\_build\x.so` 被当成**一整段**,`_build` 认不出来 —— `unmanaged-path?`
  ;; 恒假,install 的清单与 `chandler verify` 就把生成物和 `.git` 收成受管文件。
  ;; 那是本次 Windows 工作里危害最大的一处静默错误。
  (define (path-has-segment? p segs)
    (let loop ([xs (path-segments p)])
      (cond
        [(null? xs) #f]
        [(member (car xs) segs) #t]
        [else (loop (cdr xs))])))

  ;; 不受 lock/manifest 文件清单管辖的路径段:.git 是仓库元数据,_build 是生成物。
  (define unmanaged-path-segments '(".git" "_build"))

  (define (unmanaged-path? rel) (path-has-segment? rel unmanaged-path-segments))

  ;; ── 相对化 ──
  ;; root 下的绝对路径 → 相对 root 的路径。
  ;;
  ;; **不能做裸字符串前缀匹配**:Windows 上 root 常是我们自己拼的(`/` 形),
  ;; 而 abs 来自 Chez 的 `directory-list` / `current-directory`(`\` 形)——
  ;; 前缀对不上,strip-prefix 原样返回,于是「相对路径」其实是绝对路径,
  ;; 悄悄进了 lock 的 `(files …)`。改为**按段比较**。
  ;;
  ;; 返回值的分隔符归一到 `/`:这些相对路径会被写进 lock / 清单并跨平台比对,
  ;; 必须是同一种写法(见 normalize-seps 的注释)。
  (define (relativize root abs)
    (let loop ([rs (path-segments root)] [as (path-segments abs)])
      (cond
        ;; root 段耗尽 → 剩下的就是相对部分
        [(null? rs) (string-join as "/")]
        ;; abs 比 root 短,或某一段对不上 → 不在 root 之下,原样归还(归一分隔符)
        [(or (null? as) (not (string=? (car rs) (car as)))) (normalize-seps abs)]
        [else (loop (cdr rs) (cdr as))])))

  ;; files-under 的相对形:扫 <root>/<sub>,结果相对 **root**(不是 sub)。
  (define (rel-files-under root sub)
    (map (lambda (abs) (relativize root abs))
         (files-under (path-join* root sub))))

  ;; 系统临时目录(尊重 TMPDIR;修 compile/recipe 硬编码 /tmp 的可移植性 bug)
  ;; 依次:`TMPDIR`(POSIX 惯例)→ `TEMP` / `TMP`(Windows 惯例)→ 平台默认。
  ;; 空串视为未设(与 util 的 getenv* 同语义:Chez 的 putenv 删不掉变量,
  ;; 还原时只能置 "")。
  ;;
  ;; 先前只认 `TMPDIR`,于是 Windows 上**所有**临时文件都写向一个不存在的
  ;; `/tmp`:proc 的 make-temp-dir、compile 的编译器探测与并行 fp-tmp、
  ;; recipe 的 run/capture、pack 的 skiff 版本探测,全在这条路径上。
  (define (system-temp-dir)
    (or (env-nonempty "TMPDIR")
        (env-nonempty "TEMP")
        (env-nonempty "TMP")
        (if (windows-paths?) "C:/Windows/Temp" "/tmp")))

  (define (env-nonempty name)
    (let ([v (getenv name)])
      (and v (> (string-length v) 0) v)))

  ;; 本机是否 Windows。fs 是最底层库(只依赖 util),不能 import layout 拿
  ;; windows-mt?(layout 依赖 fs,会成环)—— 故这里按 machine-type 自己判一次。
  ;; 判据与 layout 的 windows-mt? 同为「machine-type 以 nt 结尾」。
  (define (windows-paths?)
    (let ([m (symbol->string (machine-type))])
      (and (>= (string-length m) 2)
           (string=? "nt" (substring m (- (string-length m) 2) (string-length m)))))))
