use strict; use JSON::PP; use POSIX qw(strftime mktime);
my $home=$ENV{HOME}; my $uid=$ARGV[0] or die "用法: perl -e <userId>  (Mirasim 流水里的 userId,如 usr_xxx)\n"; my $BF=296800;
sub iso2t { my($s)=@_; my($Y,$M,$D,$h,$m,$sec)=$s=~/(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/; $ENV{TZ}="UTC"; return mktime($sec,$m,$h,$D,$M-1,$Y-1900) }
my $js=JSON::PP->new; local $/; open my $fh,"<","$home/Library/Application Support/EduHuan/samples.json" or die; my $arr=$js->decode(<$fh>); close $fh;
my @fs; for my $s (@$arr){ next unless $s->{user} eq $uid && $s->{window} eq "7d_fable"; push @fs,[iso2t($s->{at}),$s->{percent}/100*$BF] } @fs=sort{$a->[0]<=>$b->[0]}@fs;
sub ptsAt { my($t)=@_; my $best; for my $p (@fs){ my $d=abs($p->[0]-$t); $best=[$d,$p->[1]] if !$best||$d<$best->[0] } return ($best&&$best->[0]<=150)?$best->[1]:undef }
my %R=( f51=>[10,50,0.25,12.5], f5=>[10,50,1,12.5] );
sub usd { my($r,$o)=@_; ($o->{input}*$r->[0]+$o->{output}*$r->[1]+$o->{cacheRead}*$r->[2]+$o->{cacheWrite}*$r->[3])/1e6 }
my $wstart=iso2t("2026-09-01T05:41:25Z"); my $tEnd=$fs[-1][0]; my $usedF=$fs[-1][1];
my (%H,%W); open $fh,"<","$home/.mirasim/insights/usage-2026-09.ndjson" or die; local $/="\n";
while(my $l=<$fh>){ next unless $l=~/"leg":"relay"/ && $l=~/"status":200/ && $l=~/"userId":"$uid"/ && $l=~/"model":"claude-fable/; my $o=eval{$js->decode($l)} or next; my $t=iso2t($o->{ts}); my $c=$o->{model} eq "claude-fable-5-1"?"f51":"f5"; my $h=int($t/3600)*3600;
  $H{$h}{$c}{own}+=usd($R{$c},$o); $H{$h}{$c}{f5}+=usd($R{f5},$o); $H{$h}{$c}{f51}+=usd($R{f51},$o); $H{$h}{$c}{tok}+=$o->{input}+$o->{output}+$o->{cacheRead}+$o->{cacheWrite}; $H{$h}{$c}{read}+=$o->{cacheRead};
  if($t>=$wstart && $t<=$tEnd){ $W{$c}{own}+=usd($R{$c},$o); $W{$c}{f5}+=usd($R{f5},$o); $W{$c}{f51}+=usd($R{f51},$o); $W{$c}{n}++ } }
close $fh; $ENV{TZ}="Asia/Shanghai";
print "=== 只有 Fable 5.1 在跑的小时(Fable 窗的点全是 5.1 扣的) ===\n";
printf "%-9s %8s | %7s %7s | %7s %7s | %s\n","小时","Fable点","按5.1\$","按F5\$","点/5.1\$","点/F5\$","缓读占比";
my %A;
for my $h (sort {$a<=>$b} keys %H){ my $r=$H{$h}; next unless ($r->{f51}{own}//0)>1 && ($r->{f5}{own}//0)<1; my $a=ptsAt($h); my $b=ptsAt($h+3600); next unless defined $a && defined $b; my $df=$b-$a; next if $df<500;
  printf "%-9s %8.0f | %7.1f %7.1f | %7.0f %7.0f | %.0f%%\n", strftime("%d日%H时",localtime($h)), $df, $r->{f51}{own}, $r->{f51}{f5}, $df/$r->{f51}{own}, $df/$r->{f51}{f5}, $r->{f51}{read}/$r->{f51}{tok}*100; $A{pts}+=$df; $A{own}+=$r->{f51}{own}; $A{f5}+=$r->{f51}{f5} }
printf "合计: 点/5.1\$ = %.0f, 点/F5价\$ = %.0f\n", $A{pts}/$A{own}, $A{pts}/$A{f5} if $A{pts};
print "\n=== 整个 Fable 窗口分解(窗起 09-01 13:41 → 最后样本 ".strftime("%m-%d %H:%M",localtime($tEnd)).", 窗已用 ".sprintf("%.0f",$usedF)." 点) ===\n";
my $p5=200*$W{f5}{f5}; printf "Fable 5: %d 次, 按 F5 价 \$%.0f → 若 200 点/\$ 应扣 %.0f 点\n", $W{f5}{n}, $W{f5}{f5}, $p5;
my $rest=$usedF-$p5; printf "余下归 5.1 的点: %.0f (5.1 共 %d 次, 按 5.1 价 \$%.0f, 按 F5 价 \$%.0f)\n", $rest, $W{f51}{n}, $W{f51}{own}, $W{f51}{f5};
printf "  假设A(与 Fable 5 同权重, 200 点/F5价\$): 预测 %.0f 点  偏差 %+.1f%%\n", 200*$W{f51}{f5}, (200*$W{f51}{f5}/$rest-1)*100;
printf "  假设B(300 点/5.1价\$):                 预测 %.0f 点  偏差 %+.1f%%\n", 300*$W{f51}{own}, (300*$W{f51}{own}/$rest-1)*100;
printf "  假设C(200 点/5.1价\$, 点也便宜了):      预测 %.0f 点  偏差 %+.1f%%\n", 200*$W{f51}{own}, (200*$W{f51}{own}/$rest-1)*100;
