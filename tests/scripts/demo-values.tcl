# Appended to examples/demo.tcl by tests/demo.sh. It prints the values that do not depend on the theme.
update
puts "children: [winfo children .]"
puts "grid size: [grid size .]"
foreach w [winfo children .] { puts "$w: [grid info $w]" }
puts "title: [wm title .]"
.name insert 0 Ada
.greet invoke
puts "greet: msg=$msg name=$name"
.count invoke
.count invoke
puts "count: msg=$msg count=$count"
event generate .title <Enter>
puts "enter: msg=$msg"
event generate .title <Leave>
puts "leave: msg=$msg"
puts "bind .name: [bind .name]"
puts "bind .: [bind .]"
exit
