if (strstrt(GPVAL_TERMINALS, "pngcairo") > 0) { set terminal pngcairo size 1100,600 font "Arial,10" } else { set terminal png size 1100,600 }
set datafile missing "nan"
set grid
set key top right
set output "form_fit_results/fit.png"
set title "form_fit: y = sin(x)" noenhanced
set xlabel "x"
set ylabel "y"
plot "form_fit_results/curve.dat" using 1:2 with lines lw 2 lc rgb "#d62728" title "evolved function", \
     "form_fit_results/data.dat" using 1:2 with points pt 7 ps 0.8 lc rgb "#1f77b4" title "data"
set output "form_fit_results/convergence.png"
set title "Convergence (normalised MSE)"
set xlabel "generation"
set ylabel "NMSE"
set logscale y
set xrange [0:1]
set format y "%.0e"
plot "form_fit_results/history.txt" using 1:2 with lines lw 2 lc rgb "#d62728" title "best", \
     "form_fit_results/history.txt" using 1:3 with lines lw 2 lc rgb "#7f7f7f" title "population median"
