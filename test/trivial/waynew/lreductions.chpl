// Test logical AND and OR arithmetic reductions

param M = 10;

var D: domain(1) = [1..M];
var B: [D] bool;
forall i in D do {
  B(i) = true;
}
writeln( "\nB[D] = ", B);
writeln( "land B[D] = ", land reduce B);
writeln( "lor B[D] = ", lor reduce B);

forall i in D do {
  B(i) = false;
}
writeln( "\nB[D] = ", B);
writeln( "land B[D] = ", land reduce B);
writeln( "lor B[D] = ", lor reduce B);

var toggle: bool = false;
forall i in D do {
  toggle = !toggle;
  B(i) = toggle;
}
writeln( "\nB[D] = ", B);
writeln( "land B[D] = ", land reduce B);
writeln( "lor B[D] = ", lor reduce B);
