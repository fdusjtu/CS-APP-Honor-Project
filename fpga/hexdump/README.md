HEXDUMP.EXE FOR WINDOWS
=======================

A simplified version of the Linux utility to display file contents in hexadecimal.

	>hexdump -h
	Usage: hexdump [OPTION]... [FILE]
	Display contents of FILE in hexadecimal.
	With no FILE, read standard input.
	 -C Canonical hex+ASCII display: add display of bytes as printable ASCII chars
	 -O omit offset column
	 -H add ASCII display with escaped Html entities (e.g. '&' --> '&amp;')
	 -R add display of bytes in Raw format
	 -V display version information and exit
	 -h display this help and exit
 
	>hexdump abc.txt
	000000  61 62 63

	>hexdump -C mexico-utf8.txt
	000000  4f 6c c3 a1 20 6d 75 6e 64 6f 20 4d c3 a9 78 69  Ol.. mundo M..xi
	000010  63 6f 20 3c 26 3e 0d 0a                          co <&>..

For more help, see <https://www.di-mgt.com.au/hexdump-for-windows.html>.
	
David Ireland  
DI Management Services Pty Ltd  
Australia  
<http://www.di-mgt.com.au/contact/>  
First published 2010-05-10. Version 2.1.0 compiled 2023-11-01.	
