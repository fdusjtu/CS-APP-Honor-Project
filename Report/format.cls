\NeedsTeXFormat{LaTeX2e}[1995/12/01]
\ProvidesClass{Format}

\LoadClass[UTF8, a4paper, 12pt]{ctexart}

\RequirePackage{ifxetex}
\RequireXeTeX
\ifxetex\else
\ClassError{Format}{You must use the `xelatex' driver\MessageBreak Please choose `xelatex'}{%
Just choose `xelatex', no `pdflatex' or `latex' and so on.}
\fi

% 页面布局
\RequirePackage{geometry}
    \geometry{left=20mm, right=20mm, top=25mm, bottom=25mm}
    % \geometry{left=1in, right=1in, top=1in, bottom=1in}
    \renewcommand*{\baselinestretch}{1.38}

% 超链接
\RequirePackage{hyperref}
    % \RequirePackage[hyphens]{url}
    % \Urlmuskip=0mu plus 1mu  % 增加换行可能性
\RequirePackage{fontspec} % 字体设置的宏包
\RequirePackage{newtx}
% \RequirePackage{newtxtext}
% 数学公式和符号的宏包集合
\RequirePackage{amsmath}
\RequirePackage{amsfonts}
\RequirePackage{graphicx}
\RequirePackage{subfigure}
\let\Bbbk\relax
\RequirePackage{amssymb}
\RequirePackage{bm}
\let\openbox\relax
\RequirePackage{amsthm}
\RequirePackage{mathrsfs}
\RequirePackage{mathtools}
\RequirePackage{physics}
\RequirePackage{breqn}
\RequirePackage{upgreek}
% \RequirePackage{siunitx}

% 算法和伪代码的宏包
\RequirePackage{algorithm}
\RequirePackage{algorithmicx}
\RequirePackage[noend]{algpseudocode}
% 自定义页眉页脚
\RequirePackage{fancyhdr}
\pagestyle{fancy}
    \fancyhf{}
    % 页眉设置
    \fancyhead[L]{\@title}
    \fancyhead[C]{}
    \fancyhead[R]{日期：\@date}
    % 页脚设置
    \fancyfoot[L]{}
    \fancyfoot[C]{\thepage} % 页码
    \fancyfoot[R]{}
    % % 分隔线宽度
    % \renewcommand{\headrulewidth}{0pt}
    % \renewcommand{\footrulewidth}{0pt}
% 创建带边框的框架的宏包
\RequirePackage[framemethod=TikZ]{mdframed} 
\RequirePackage{xeCJK}
\RequirePackage{adjustbox} % 调整盒子大小的宏包
\RequirePackage{fontsize} % 设置字体大小的宏包

\ctexset{
    section = {
        % 一级标题：三号黑体加粗居中
        format = {\zihao{3}\sffamily\bfseries\centering}
    },
    subsection = {
        % 二级标题：四号黑体加粗居左
        format = {\zihao{4}\sffamily\bfseries\raggedright}
    },
    subsubsection = {
        % 三级标题：小四号黑体加粗居左
        format = {\zihao{-4}\sffamily\bfseries\raggedright}
    },
    paragraph = {
        format = {\zihao{-4}\sffamily\bfseries}
    }
}
\setlength{\parskip}{0.5em} %段前段后0.5行

% 标题格式
\renewcommand{\maketitle}{
    \begin{center}
        \vspace*{0cm}
        \zihao{2} \textsf{\textbf{\@title}}
        
        \zihao{-4} \@date
    \end{center}
    \zihao{-4} % 正文小四号
    \vspace*{0cm}
}

\RequirePackage{tikz,xcolor} % 绘制图形和使用颜色的宏包
\RequirePackage{multicol} % 多栏排版的宏包
\RequirePackage{multirow} % 表格中合并单元格的宏包
\RequirePackage{pdfpages} % 插入PDF文件的宏包
\RequirePackage{listings} % 在文档中插入源代码的宏包
\RequirePackage{xcolor} % 定义和使用颜色的宏包
\RequirePackage{wrapfig} % 文字绕排图片的宏包
\RequirePackage{bigstrut,multirow,rotating} % 支持在表格中使用特殊命令的宏包
\RequirePackage{booktabs} % 创建美观的表格的宏包
% \RequirePackage{circuitikz} % 绘制电路图的宏包
%     \ctikzset{tripoles/pmos style=emptycircle}
%     % \ctikzset{near i/.style={current/distance=0.1}}
\RequirePackage[capitalize]{cleveref}% 轻松引用, 可以用\cref{}指令直接引用, 自动加前缀.
\RequirePackage{dirtree}
\RequirePackage{caption}
\RequirePackage{enumitem}
\RequirePackage{makecell}
\RequirePackage{listings}
\RequirePackage[titletoc,title]{appendix}
\renewcommand{\appendixname}{附录}
\RequirePackage[toc, acronym]{glossaries}
% \renewcommand{\acronymname}{缩略语表}
\renewcommand{\glossaryname}{术语表}
\GlsSetXdyLanguage{Chinese}

\definecolor{dkgreen}{rgb}{0,0.6,0}
\definecolor{gray}{rgb}{0.5,0.5,0.5}
\definecolor{mauve}{rgb}{0.58,0,0.82}

\definecolor{commentcolor}{RGB}{92, 92, 92}
\definecolor{keywordcolor}{RGB}{0, 102, 204}
\definecolor{typecolor}{RGB}{0, 150, 0}
\definecolor{stringcolor}{RGB}{209, 28, 36}
\definecolor{numbercolor}{RGB}{128, 0, 128}
\definecolor{backcolor}{RGB}{247, 247, 247}

% Scala/Chisel高亮配置增强版
\lstdefinelanguage{Scala}{
  morekeywords={
    abstract,case,catch,class,def,do,else,extends,false,final,
    finally,for,forSome,if,implicit,import,lazy,match,new,null,
    object,override,package,private,protected,return,sealed,super,
    this,throw,trait,true,try,type,val,var,while,with,yield
  },
  sensitive=true,
  morecomment=[l]{//},
  morecomment=[s]{/*}{*/},
  morestring=[b]",
  morestring=[b]'
}

% 为Chisel定制类型关键字
\lstdefinelanguage{Chisel}{
  language=Scala,
  morekeywords={
    UInt,SInt,Bool,Input,Output,Wire,Reg,RegInit,Module,Bundle,
    IO,Flipped,Mux,MuxCase,MuxLookup,Cat,Fill,Vec,when,otherwise,
    switch,is,true,false
  }
}

\lstset{ % listings 全局设置
  language=Chisel,
  basicstyle=\ttfamily\zihao{6},
  % aboveskip=1mm,
  % belowskip=1mm,
  keywordstyle=\color{keywordcolor}\bfseries,
  keywordstyle=[2]\color{typecolor}\bfseries, % 自定义类型关键字
  commentstyle=\color{commentcolor}\itshape,
  stringstyle=\color{stringcolor},
  numberstyle=\color{commentcolor}\sffamily,
  numbers=left,
  % stepnumber=1,
  numbersep=10pt,
  backgroundcolor=\color{backcolor},
  frame=single,
  rulecolor=\color{black!30},
  frameround=tttt, % 圆角边框
  showspaces=false,
  showstringspaces=false,
  showtabs=false,
  tabsize=2,
  captionpos=b,
  breaklines=true,
  breakatwhitespace=true,
  escapeinside={(*@}{@*)},
}

% 浮动环境设置
% 默认情况下, \LaTeX{} 要求每页的文字至少占据 20%,否则该页就只单独放置一个浮动环境,
% 而这通常不是我们想要的, 我们将这个要求降低到 5%.
 \renewcommand*{\textfraction}{0.05}
% 有时如果多个浮动环境连续放在一起, \LaTeX{}
% 会将它们分在几个不同页，即使它们可在同一页放
% 得下. 我们可以通过修改 |\topfraction| 和 |\bottomfraction| 分别设置顶端和底端的浮
% 动环境的最大比例.
 \renewcommand*{\topfraction}{0.9}
 \renewcommand*{\bottomfraction}{0.8}
% 有时\LaTeX{}会把一个浮动环境单独放在一页,
% 我们要求这个环境至少要占据 85% 才能单独放在一页.
% 注意:  |\floatpagefraction| 的数值必须小于 |\topfraction|.
 \renewcommand*{\floatpagefraction}{0.85}
% 关于图片 graphicx
 % 如果图片没有指定后缀, 依次按下列顺序搜索
\DeclareGraphicsExtensions{.pdf,.eps,.jpg,.png}
 % 设置图表搜索路径, 可以给图表文件夹取如下名字
\graphicspath{{figures/}{figure/}{pictures/}%
  {picture/}{pic/}{pics/}{image/}{images/}}
% 图表标题
% \captionsetup{font={small}, labelfont={bf}, labelsep={colon}, justification=centering}
\captionsetup[figure]{
	format=hang,
	labelsep=quad,
	font={bf},
	position=bottom
}
\captionsetup[table]{
	format=hang,
	labelsep=quad,
	font={bf},
	position=top
}
% enumitem设置
\setlist{%
	topsep=0.3em, % 列表顶端的垂直空白
	partopsep=0pt, % 列表环境前面紧接着一个空白行时其顶端的额外垂直空白
	itemsep=0ex plus 0.1ex, % 列表项之间的额外垂直空白
	parsep=0pt, % 列表项内的段落之间的垂直空白
	% leftmargin=1em, % 环境的左边界和列表之间的水平距离
	rightmargin=2em, % 环境的右边界和列表之间的水平距离
	% labelsep=0.5em, % 包含标签的盒子与列表项的第一行文本之间的间隔
	% labelwidth=2em % 包含标签的盒子的正常宽度；若实际宽度更宽，则使用实际宽度。
    % itemindent=1em, 
    listparindent=2em, 
}
% 超链接
\hypersetup{%
    %  xetex,
    % unicode=false, % hyperref 和 xetex 同时使用时不能开启 Unicode 选项.
    pdfstartview=FitH,
    CJKbookmarks=true,
    bookmarksnumbered=true,
    bookmarksopen=true,
    colorlinks, %注释掉此项则交叉引用为彩色边框(将colorlinks和pdfborder同时注释掉)
    pdfborder=001,   %注释掉此项则交叉引用为彩色边框
    allcolors=black,
    breaklinks=true
}%
   
\pdfstringdefDisableCommands{%
	\def\cftdotfill{ }%
}

%%% crefformat settings
\crefformat{figure}{#2图~#1#3}
% \crefrangeformat{figure}{图~(#3#1#4)\;\~{}\;(#5#2#6)}
% \crefmultiformat{figure}{图~(#2#1#3)}{和~(#2#1#3)}{，(#2#1#3)}{和~(#2#1#3)}

\crefformat{table}{#2表~#1#3}
% \crefrangeformat{table}{表~(#3#1#4)\;\~{}\;(#5#2#6)}
% \crefmultiformat{table}{表~(#2#1#3)}{和~(#2#1#3)}{，(#2#1#3)}{和~(#2#1#3)}

\crefformat{equation}{#2式~(#1#3)}
% \crefrangeformat{equation}{式~(#3#1#4)\;\~{}\;(#5#2#6)}
% \crefmultiformat{equation}{式~(#2#1#3)}{ 和~(#2#1#3)}{，(#2#1#3)}{ 和~(#2#1#3)}

\crefformat{section}{#2~#1~节#3}

\crefformat{listing}{#2代码片段~#1#3}

\renewcommand{\lstlistingname}{代码片段}

% \renewcommand{\thefootnote}{[\arabic{footnote}]}

% 定义公式编号样式
\renewcommand{\theequation}{\thechapter.\arabic{equation}} % 公式按章节编号
\makeatletter
\@addtoreset{equation}{section}  % 每节重新编号公式
\makeatother