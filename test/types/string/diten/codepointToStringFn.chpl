proc main {
  var s = "Hello World";

  for i in 0..#s.length {
    var aint = s.byte(i);
    write(aint, " ");
    var astr = codepointToString(aint);
    writeln(astr);
  }
}
