use LinearAlgebra;
use UnitTest;

config const n=10;
config const thresh=1.0e-10;

proc isClose(a, b) {
  return (+ reduce (a-b)) < thresh;
}

// Modified sinMatrix function
proc sinMatrix(n) {
  var A = Matrix(n);
  const fac0 = 1.0/(n+1.0);
  const fac1 = sqrt(2.0*fac0);
  for (i,j) in {1..n,1..n} {
    A[i,j] = fac1*sin(i*j*pi*fac0) + 0.1; // modification is +0.1, otherwise the matrix is equal to its inverse
  }
  return A;
}

var invA = inv(sinMatrix(n));
writeln(invA);
writeln();

var I = dot(sinMatrix(n), invA);
writeln(I);
writeln();

writeln(isClose(I, eye(n)));
