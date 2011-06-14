# -*- coding: UTF-8 -*-
from collections import defaultdict
from itertools import islice, chain, count
from operator import itemgetter
from functools import partial
from pprint import pprint
from math import log, exp, fsum
from heapq import nlargest
import cPickle, re, time, codecs
from nltk import FreqDist, Tree
from nltk.metrics import precision, recall, f_measure, accuracy
#import plac
from kbest import lazykbest
from negra import NegraCorpusReader, fold, unfold
from grammar import srcg_productions, dop_srcg_rules, induce_srcg, enumchart,\
		export, read_rparse_grammar, mean, harmean, testgrammar,\
		bracketings, printbrackets, rem_marks, alterbinarization, terminals,\
		varstoindices, read_bitpar_grammar, read_penn_format, newsplitgrammar
from fragmentseeker import extractfragments
from treetransforms import collinize, un_collinize, binarizetree
try: from plcfrs_cython import parse, mostprobableparse, mostprobablederivation
except: from plcfrs import parse, mostprobableparse, mostprobablederivation

def main(
	#parameters. parameters. PARAMETERS!!
	srcg = True,
	dop = True,
	unfolded = False,
	maxlen = 15,  # max number of words for sentences in training & test corpus
	bintype = "collinize", # choices: collinize, nltk, optimal
	estimator = "sl-dop", # choices: dop1, ewe, shortest, sl-dop
	factor = "right",
	v = 1,
	h = 1,
	minMarkov = 3,
	tailmarker = "",
	train = 7200,
	maxsent = 360,	# number of sentences to parse
	sample = False,
	both = False,
	arity_marks = True,
	arity_marks_before_bin = False,
	interpolate = 1.0,
	wrong_interpolate = False,
	m = 1000,		#number of derivations to sample/enumerate
	prune=True,	#whether to use srcg chart to prune parsing of dop
	sldop_n=7,
	doestimates=False,
	useestimates=False
	):
	# Tiger treebank version 2 sample:
	# http://www.ims.uni-stuttgart.de/projekte/TIGER/TIGERCorpus/annotation/sample2.export
	#corpus = NegraCorpusReader(".", "sample2\.export", encoding="iso-8859-1"); maxlen = 99
	#corpus = NegraCorpusReader("../rparse", "tiger3600proc.export", headfinal=True, headreverse=False)

	assert bintype in ("optimal", "collinize", "nltk")
	assert estimator in ("dop1", "ewe", "shortest", "sl-dop")
	if isinstance(train, float):
		train = int(train * len(corpus.sents()))
	if train > 7200:
		corpus = NegraCorpusReader("../rparse", "tigerprocfull.export",
			headorder=(bintype=="collinize"), headfinal=True,
			headreverse=False, unfold=unfolded)
	else:
		corpus = NegraCorpusReader("../rparse", "tigerprocfull.export",
			headorder=(bintype=="collinize"), headfinal=True,
			headreverse=False, unfold=unfolded)
	trees, sents, blocks = corpus.parsed_sents()[:train], corpus.sents()[:train], corpus.blocks()[:train]
	trees, sents, blocks = zip(*[sent for sent in zip(trees, sents, blocks) if len(sent[1]) <= maxlen])
	# parse training corpus as a "soundness check"
	#test = corpus.parsed_sents(), corpus.tagged_sents(), corpus.blocks()
	if train > 7200:
		test = NegraCorpusReader("../rparse", "tigerprocfull.export")
	else:
		test = NegraCorpusReader("../rparse", "tigerproc.export")
	test = test.parsed_sents()[train:], test.tagged_sents()[train:], test.blocks()[train:]
	print "read training & test corpus"
	if arity_marks_before_bin: [srcg_productions(a, b) for a, b in zip(trees, sents)]
	if bintype == "collinize":
		bintype += " %s h=%d v=%d %s markovize rank > %d" % (factor, h, v, "tailmarker" if tailmarker else '', minMarkov)
		[collinize(a, factor=factor, vertMarkov=v-1, horzMarkov=h, tailMarker=tailmarker, minMarkov=minMarkov) for a in trees]
	if bintype == "nltk":
		bintype += " %s h=%d v=%d" % (factor, h, v)
		for a in trees: a.chomsky_normal_form(factor="left", vertMarkov=v-1, horzMarkov=1)
	if bintype == "optimal": trees = [binarizetree(tree.freeze()) for tree in trees]
	print "binarized", bintype

	#trees = trees[:10]; sents = sents[:10]
	seen = set()
	v = set(); e = {}; weights = {}
	for n, (tree, sent) in enumerate(zip(trees, sents)):
		rules = [(a,b) for a,b in induce_srcg([tree], [sent]) if a not in seen]
		seen.update(map(lambda (a,b): a, rules))
		match = False
		for (rule,yf), w in rules:
			if len(rule) == 2 and rule[1] != "Epsilon":
				#print n, rule[0], "-->", rule[1], "\t\t", [list(a) for a in yf]
				match = True
				v.add(rule[0])
				e.setdefault(rule[0], set()).add(rule[1])
				weights[rule[0],rule[1]] = w
		if False and match:
			print tree
			print n, sent

	def visit(current, edges, visited):
		""" depth-first cycle detection """
		for a in edges.get(current, set()):
			if a in visited:
				visit.mem.add(current)
				yield visited[visited.index(a):] + [a]
			elif a not in visit.mem:
				for b in visit(a, edges, visited + [a]): yield b
	visit.mem = set()
	for a in v:
		for b in visit(a, e, []):
			print "cycle", b, "cost", sum(weights[c,d] for c,d in zip(b, b[1:]))

	for interp in range(0, 1): #disable interpolation
		interpolate = 1.0 #interp / 10.0
		#print "INTERPOLATE", interpolate
		grammar = []; dopgrammar = []
		if srcg:
			grammar = induce_srcg(list(trees), sents)
			#for (rule,yf),w in sorted(grammar, key=lambda x: x[0][0][0]):
			#	if len(rule) == 2 and rule[1] != "Epsilon":
			#		print exp(w), rule[0], "-->", " ".join(rule[1:]), "\t\t", [list(a) for a in yf]
			#grammar = read_rparse_grammar("../rparse/bin3600")
			lhs = set(rule[0] for (rule,yf),w in grammar)
			print "SRCG based on", len(trees), "sentences"
			l = len(grammar)
			print "labels:", len(set(rule[a] for (rule,yf),w in grammar for a in range(3) if len(rule) > a)), "of which preterminals:", len(set(rule[0] for (rule,yf),w in grammar if rule[1] == "Epsilon")) or len(set(rule[a] for (rule,yf),w in grammar for a in range(1,3) if len(rule) > a and rule[a] not in lhs))
			print "max arity:", max((len(yf), rule, yf, w) for (rule, yf), w in grammar)
			print "max vars:", max((max(map(len, yf)), rule, yf, w) for (rule, yf), w in grammar if rule[1] != "Epsilon")
			grammar = newsplitgrammar(grammar)
			ll=sum(len(b) for a,b in grammar.lexical.items())
			print "clauses:",l, "lexical clauses:", ll, "non-lexical clauses:", l - ll
			testgrammar(grammar)
			print "induced srcg grammar"

		if dop:
			if estimator == "shortest":
				# the secondary model is used to resolve ties for the shortest derivation
				dopgrammar, secondarymodel = dop_srcg_rules(list(trees), list(sents), normalize=False,
								shortestderiv=True,	arity_marks=arity_marks)
			else:
				dopgrammar = dop_srcg_rules(list(trees), list(sents), normalize=(estimator in ("ewe", "sl-dop")),
								shortestderiv=False, arity_marks=arity_marks,
								interpolate=interpolate, wrong_interpolate=wrong_interpolate)
				#dopgrammar = dop_srcg_rules(list(trees), list(sents), normalize=(estimator in ("ewe", "sl-dop")),
				#				shortestderiv=False, arity_marks=arity_marks,
				#				interpolate=interpolate, wrong_interpolate=wrong_interpolate)
			nodes = sum(len(list(a.subtrees())) for a in trees)
			l = len(dopgrammar)
			print "labels:", len(set(rule[a] for (rule,yf),w in dopgrammar for a in range(3) if len(rule) > a)), "of which preterminals:", len(set(rule[0] for (rule,yf),w in dopgrammar if rule[1] == "Epsilon")) or len(set(rule[a] for (rule,yf),w in dopgrammar for a in range(1,3) if len(rule) > a and rule[a] not in lhs))
			print "max arity:", max((len(yf), rule, yf, w) for (rule,yf),w in dopgrammar)
			dopgrammar = newsplitgrammar(dopgrammar)
			ll=sum(len(b) for a,b in dopgrammar.lexical.items())
			print "clauses:",l, "lexical clauses:", ll, "non-lexical clauses:", l - ll
			testgrammar(dopgrammar)
			print "DOP model based on", len(trees), "sentences,", nodes, "nodes,", len(dopgrammar.toid), "nonterminals"

		if doestimates:
			from estimates import getestimates
			import numpy as np
			print "computing estimates"
			begin = time.clock()
			outside = getestimates(grammar, maxlen, grammar.toid["ROOT"])
			print "done. time elapsed: ", time.clock() - begin,
			np.savez("outside.npz", outside=outside)
			#cPickle.dump(outside, open("outside.pickle", "wb"))
			print "saved estimates"
		if useestimates:
			import numpy as np
			#outside = cPickle.load(open("outside.pickle", "rb"))
			outside = np.load("outside.npz")['outside']
			print "loaded estimates"
		else: outside = None

		#for a,b in extractfragments(trees).items():
		#	print a,b
		#exit()
		results = doparse(srcg, dop, estimator, unfolded, bintype, sample,
				both, arity_marks, arity_marks_before_bin, interpolate,
				wrong_interpolate, m, grammar, dopgrammar, test, maxlen,
				maxsent, prune, sldop_n, useestimates, outside)
		doeval(*results)

def doparse(srcg, dop, estimator, unfolded, bintype, sample, both, arity_marks, arity_marks_before_bin, interpolate, wrong_interpolate, m, grammar, dopgrammar, test, maxlen, maxsent, prune, sldop_n=14, useestimates=False, outside=None, top='ROOT', tags=True):
	sresults = []; dresults = []
	serrors1 = FreqDist(); serrors2 = FreqDist()
	derrors1 = FreqDist(); derrors2 = FreqDist()
	gold = []; gsent = []
	scandb = set(); dcandb = set(); goldbrackets = set()
	nsent = exact = exacts = snoparse = dnoparse =  0
	estimate = lambda a,b: 0.0
	removeids = re.compile("@[0-9]+")
	#if srcg: derivout = codecs.open("srcgderivations", "w", encoding='utf-8')
	for tree, sent, block in zip(*test):
		if len(sent) > maxlen: continue
		if nsent >= maxsent: break
		nsent += 1
		print "%d. [len=%d] " % (nsent, len(sent)),
		myprint(u" ".join(a[0]+u"/"+a[1] for a in sent))
		goldb = bracketings(tree)
		gold.append(block)
		gsent.append(sent)
		goldbrackets.update((nsent, a) for a in goldb)
		if srcg:
			print "SRCG:",
			begin = time.clock()
			chart, start = parse([w for w,t in sent], grammar,
						tags=[t for w,t in sent] if tags else [],
						start=grammar.toid[top], exhaustive=prune,
						estimate=(outside, maxlen) if useestimates else None)
			print " %.2fs cpu time elapsed" % (time.clock() - begin)
		else: chart = {}; start = False
		#for a in chart: chart[a].sort()
		#for result, prob in enumchart(chart, start, grammar.tolabel) if start else ():
		if repr(start) != "0[0]":
			result, prob = mostprobablederivation(chart, start, grammar.tolabel)
			#result = rem_marks(Tree(alterbinarization(result)))
			#print result
			#derivout.write("vitprob=%.6g\n%s\n\n" % (
			#				exp(-prob), terminals(result,  sent)))
			result = Tree(result)
			un_collinize(result)
			rem_marks(result)
			if unfolded: fold(result)
			print "p = %.4e" % (exp(-prob),),
			candb = bracketings(result)
			prec = precision(goldb, candb)
			rec = recall(goldb, candb)
			f1 = f_measure(goldb, candb)
			if result == tree or f1 == 1.0:
				assert result != tree or f1 == 1.0
				print "exact match"
				exacts += 1
			else:
				print "LP %5.2f LR %5.2f LF %5.2f" % (
								100 * prec, 100 * rec, 100 * f1)
				print "cand-gold", printbrackets(candb - goldb),
				print "gold-cand", printbrackets(goldb - candb)
				print "     ", result.pprint(margin=1000)
				serrors1.update(a[0] for a in candb - goldb)
				serrors2.update(a[0] for a in goldb - candb)
			sresults.append(result)
		else:
			if srcg: print "no parse"
			#derivout.write("Failed to parse\nparse_failure.\n\n")
			result = Tree(top, [Tree("PN", [i]) for i in range(len(sent))])
			candb = bracketings(result)
			prec = precision(goldb, candb)
			rec = recall(goldb, candb)
			f1 = f_measure(goldb, candb)
			snoparse += 1
			sresults.append(result)
		scandb.update((nsent, a) for a in candb)
		if dop:
			print "DOP:",
			#estimate = partial(getoutside, outside, maxlen, len(sent))
			if srcg and prune and repr(start) != "0[0]":
				srcgchart = chart
			else: srcgchart = {}
			begin = time.clock()
			chart, start = parse([a[0] for a in sent], dopgrammar,
								[a[1] for a in sent] if tags else [],
								dopgrammar.toid[top], True, None,
								prune=srcgchart,
								prunetoid=grammar.toid)
			print " %.2fs cpu time elapsed" % (time.clock() - begin)
		else: chart = {}; start = False
		if dop and repr(start) != "0[0]":
			if nsent == 1:
				codecs.open("dopderivations", "w",
					encoding="utf-8").writelines(
						"vitprob=%#.6g\n%s\n" % (exp(-p),
							re.sub(r'([{}\[\]<>\^$\'])', r'\\\1',
								terminals(t, sent).replace(') (', ')(')))
						for t, p in lazykbest(dict(chart), start, m,
													dopgrammar.tolabel))
			if estimator == "shortest": # equal to ls-dop with n=1 ?
				mpp = mostprobableparse(chart, start, dopgrammar.tolabel, n=m,
						sample=sample, both=both, shortest=True,
						secondarymodel=secondarymodel).items()
			elif estimator == "sl-dop":
				# get n most likely derivations
				derivations = lazykbest(chart, start, m, dopgrammar.tolabel)
				x  = len(derivations); derivations = set(derivations)
				xx = len(derivations); derivations = dict(derivations)
				if xx != len(derivations): print "duplicates w/different probabilities", x, '=>', xx, '=>', len(derivations)
				elif x != xx: print "DUPLICATES DUPLICATES", x, '=>', len(derivations)
				# sum over Goodman derivations to get parse trees
				idsremoved = defaultdict(set)
				for t, p in derivations.items():
					idsremoved[removeids.sub("", t)].add(t)
				mpp1 = dict((tt, fsum(exp(-derivations[t]) for t in ts)) for tt, ts in idsremoved.items())
				# the number of fragments used is the number of
				# nodes (open parens), minus the number of interior
				# (addressed) nodes.
				mpp = [(tt, (-min((t.count("(") - t.count("@"))
						for t in idsremoved[tt]), mpp1[tt]))
							for tt in nlargest(sldop_n, mpp1,
								key=lambda t: mpp1[t])]
				print "(%d derivations, %d of %d parsetrees)" % (len(derivations), len(mpp), len(mpp1))
			else:
				mpp = mostprobableparse(chart, start, dopgrammar.tolabel, n=m, sample=sample, both=both).items()
			dresult, prob = max(mpp, key=itemgetter(1))
			dresult = Tree(dresult)
			if isinstance(prob, tuple):
				print "subtrees = %d, p = %.4e" % (abs(prob[0]), prob[1]),
			else:
				print "p = %.4e" % (prob,),
			un_collinize(dresult)
			rem_marks(dresult)
			if unfolded: fold(dresult)
			candb = bracketings(dresult)
			prec = precision(goldb, candb)
			rec = recall(goldb, candb)
			f1 = f_measure(goldb, candb)
			if dresult == tree or f1 == 1.0:
				print "exact match"
				exact += 1
			else:
				print "LP %5.2f LR %5.2f LF %5.2f" % (
								100 * prec, 100 * rec, 100 * f1)
				print "cand-gold", printbrackets(candb - goldb),
				print "gold-cand", printbrackets(goldb - candb)
				print "     ", dresult.pprint(margin=1000)
				derrors1.update(a[0] for a in candb - goldb)
				derrors2.update(a[0] for a in goldb - candb)
			dresults.append(dresult)
		else:
			if dop: print "\nno parse"
			dresult = Tree(top, [Tree("PN", [i]) for i in range(len(sent))])
			candb = bracketings(dresult)
			prec = precision(goldb, candb)
			rec = recall(goldb, candb)
			f1 = f_measure(goldb, candb)
			dnoparse += 1
			dresults.append(dresult)
		print "GOLD:", tree.pprint(margin=1000)
		dcandb.update((nsent, a) for a in candb)
		if srcg:
			print "srcg ex %5.2f lp %5.2f lr %5.2f lf %5.2f" % (
								100 * (exacts / float(nsent)),
								100 * precision(goldbrackets, scandb),
								100 * recall(goldbrackets, scandb),
								100 * f_measure(goldbrackets, scandb))
		if dop:
			print "dop  ex %5.2f lp %5.2f lr %5.2f lf %5.2f (delta %5.2f)" % (
								100 * (exact / float(nsent)),
								100 * precision(goldbrackets, dcandb),
								100 * recall(goldbrackets, dcandb),
								100 * f_measure(goldbrackets, dcandb),
								100 * (f_measure(goldbrackets, dcandb) - f_measure(goldbrackets, scandb)))
		print

	if srcg:
		#derivout.close()
		codecs.open("test1.srcg", "w", encoding='utf-8').writelines(
			"%s\n" % export(a,b,n + 1)
			for n,(a,b) in enumerate(zip(sresults, gsent)))
		codecs.open("test.cf.srcg", "w", encoding='utf-8').writelines(
			a.pprint(margin=999)+'\n' for a in sresults)
	if dop:
		codecs.open("test1.dop", "w", encoding='utf-8').writelines(
			"%s\n" % export(a, b, n + 1)
			for n,(a, b) in enumerate(zip(dresults, gsent)))
		codecs.open("test.cf.dop", "w", encoding='utf-8').writelines(
			a.pprint(margin=999)+'\n' for a in dresults)
	#if dop: open("interp%d.dop" % interp, "w").writelines("%s\n" % export(a,b,n) for n,(a,b) in enumerate(zip(dresults, gsent)))
	codecs.open("test1.gold", "w", encoding='utf-8').write(''.join(
		"#BOS %d\n%s\n#EOS %d\n" % (n + 1, a, n + 1) for n, a in enumerate(gold)))
	codecs.open("test.cf.gold", "w", encoding='utf-8').writelines(
		a.pprint(margin=999)+'\n' for a in test[0])

	return srcg, dop, serrors1, serrors2, derrors1, derrors2, nsent, maxlen, exact, exacts, snoparse, dnoparse, goldbrackets, scandb, dcandb, unfolded, arity_marks, bintype, estimator, sldop_n, interpolate, wrong_interpolate

def doeval(srcg, dop, serrors1, serrors2, derrors1, derrors2, nsent, maxlen,
	exact, exacts, snoparse, dnoparse, goldbrackets, scandb, dcandb,
	unfolded, arity_marks, bintype, estimator, sldop_n, interpolate,
	wrong_interpolate):
	print "maxlen", maxlen, "unfolded", unfolded, "arity marks", arity_marks, "binarized", bintype, "estimator", estimator, sldop_n if estimator == 'sl-dop' else ''
	if interpolate != 1.0: print "interpolate", interpolate, "wrong_interpolate", wrong_interpolate
	print "error breakdown, first 10 categories."
	if srcg and dop: print "SRCG (not in gold, missing from candidate), DOP (idem)"
	elif srcg: print "SRCG (not in gold, missing from candidate)"
	elif dop: print "DOP (not in gold, missing from candidate)"
	z = ((serrors1.items(), serrors2.items()) if srcg else ()) + ((derrors1.items(), derrors2.items()) if dop else ())
	for a in zip(*z)[:10]:
		print "\t".join(map(lambda x: ": ".join(map(str, x)), a))
	if srcg and nsent:
		print "SRCG:"
		print "coverage %d / %d = %5.2f %%  exact match %d / %d = %5.2f %%" % (
				nsent - snoparse, nsent, 100.0 * (nsent - snoparse) / nsent,
				exacts, nsent, 100.0 * exacts / nsent)
		print "srcg lp %5.2f lr %5.2f lf %5.2f\n" % (
				100 * precision(goldbrackets, scandb),
				100 * recall(goldbrackets, scandb),
				100 * f_measure(goldbrackets, scandb))
	if dop and nsent:
		print "DOP:"
		print "coverage %d / %d = %5.2f %%  exact match %d / %d = %5.2f %%" % (
				nsent - dnoparse, nsent, 100.0 * (nsent - dnoparse) / nsent,
				exact, nsent, 100.0 * exact / nsent)
		print "dop  lp %5.2f lr %5.2f lf %5.2f\n" % (
				100 * precision(goldbrackets, dcandb),
				100 * recall(goldbrackets, dcandb),
				100 * f_measure(goldbrackets, dcandb))

def root(tree):
	if tree.node == "VROOT": tree.node = "ROOT"
	else: tree = Tree("ROOT",[tree])
	return tree

def foo(a):
	result = Tree(a)
	un_collinize(result)
	for n, a in enumerate(result.treepositions('leaves')):
		result[a] = n
	return result.pprint(margin=999) + '\n'

def cftiger():
	#read_penn_format('../tiger/corpus/tiger_release_aug07.mrg')
	grammar = read_bitpar_grammar('/tmp/gtigerpcfg.pcfg', '/tmp/gtigerpcfg.lex')
	dopgrammar = read_bitpar_grammar('/tmp/gtiger.pcfg', '/tmp/gtiger.lex', ewe=False)
	testgrammar(grammar)
	testgrammar(dopgrammar)
	dop = True; srcg = True; unfolded = False; bintype = "collinize h=1 v=1"
	viterbi = True; sample = False; both = False; arity_marks = True
	arity_marks_before_bin = False; estimator = 'sl-dop'; interpolate = 1.0
	wrong_interpolate = False; n = 0; m = 10000; maxlen = 15; maxsent = 360
	prune = False; top = "ROOT"; tags = False; sldop_n = 5
	trees = list(islice((a for a in islice((root(Tree(a))
					for a in codecs.open(
							'../tiger/corpus/tiger_release_aug07.mrg',
							encoding='iso-8859-1')), 7200, 9600)
				if len(a.leaves()) <= maxlen), maxsent))
	lex = set(wt for tree in (root(Tree(a))
					for a in islice(codecs.open(
						'../tiger/corpus/tiger_release_aug07.mrg',
						encoding='iso-8859-1'), 7200))
				if len(tree.leaves()) <= maxlen for wt in tree.pos())
	sents = [[(t + '_' + (w if (w, t) in lex else ''), t)
						for w, t in a.pos()] for a in trees]
	for tree in trees:
		for nn, a in enumerate(tree.treepositions('leaves')):
			tree[a] = nn
	blocks = [export(*a) for a in zip(trees, sents, count())]
	test = trees, sents, blocks
	doparse(srcg, dop, estimator, unfolded, bintype, sample, both, arity_marks, arity_marks_before_bin, interpolate, wrong_interpolate, m, grammar, dopgrammar, test, maxlen, maxsent, prune, sldop_n, top, tags)

def myprint(a):
	sys.stdout.write(a)
	sys.stdout.write('\n')

if __name__ == '__main__':
	import sys
	sys.stdout = codecs.getwriter('utf8')(sys.stdout)
	#cftiger()
	#plac.call(main)
	main()
