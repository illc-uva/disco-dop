from math import exp
from nltk import Tree
import grammar, containers, treetransforms, plcfrs, kbest
from containers import Grammar

def tree_adjoining_grammar():
	""" Example of a tree-adjoining grammar (TAG) encoded as an LCFRS.
	Taken from: Chen & Vijay-Shanker (2000), Automated extraction of TAGs
	from the Penn treebank.
	Limitations:
		- no epsilon productions
	Non-terminals have identifiers to encode elementary trees of depth > 2
	"""
	print "Tree-Adjoining Grammars in LCFRS"
	print """initial trees:
(S (NP ) (VP (V fell)))
(NP (NN prices))
auxiliary trees:
(S (ADVP (RB Later) (S* ))
(VP (ADVP (RB drastically)) (VP* ))"""
	grammar = Grammar([
		((('ROOT','S'),  ((0,),)), 0.0),
		((('S', 'NP', 'VP'), ((0,1),)), 0.0),
		((('S', 'ADVP#1', 'S'), ((0,1),)), 0.0),
		((('VP', 'V#1'), ((0,),)), 0.0),
		((('VP', 'ADVP#2', 'VP'), ((0,1),)), 0.0),
		((('NP','NN#1'), ((0,),)), 0.0),
		((('ADVP#1','RB#1'),  ((0,),)), 0.0),
		((('ADVP#2','RB#2'),  ((0,),)), 0.0),
		((('RB#1', 'Epsilon'), ('Later', ())), 0.0),
		((('NN#1', 'Epsilon'), ('prices', ())), 0.0),
		((('V#1', 'Epsilon'), ('fell', ())), 0.0),
		((('RB#2', 'Epsilon'), ('drastically', ())), 0.0)])
	print grammar
	do(grammar, "prices fell".split())
	do(grammar, "prices drastically fell".split())
	do(grammar, "Later prices fell".split())
	do(grammar, "Later prices drastically fell".split())

	# taken from: slides for course Grammar Formalisms, Kallmeyer (2011),
	# Mildly Context-Sensitive Grammar Formalisms:
	# LCFRS: Relations to other Formalisms
	print "the language {d} + {a**n b**m c**m d **n} with n>0, m>=0"
	print """initial trees:
(S a (S Epsilon) F)
(F d)
auxiliary trees:
(S b S* c)"""
	grammar = Grammar([
		((('ROOT', 'a1'), ((0,),)), 0.0),
		((('ROOT', 'a2'), ((0,),)), 0.0),
		((('a1', 'a_b', 'a2'), ((0,1),)), 0.0),
		((('a1', '_a', 'a2'), ((0,1),)), 0.0),
		((('a2', '_d'), ((0,),)), 0.0),
		((('a_b', '_a', 'b'), ((0,1),)), 0.0),
		((('b', '_b', '_c'), ((0,1),)), 0.0),
		((('b', 'b_2', 'b'), ((0,1,0),)), 0.0),
		((('b_2', '_b', '_c'), ((0,),(1,))), 0.0),
		((('_a', 'Epsilon'), ('a', ())), 0.0),
		((('_b', 'Epsilon'), ('b', ())), 0.0),
		((('_c', 'Epsilon'), ('c', ())), 0.0),
		((('_d', 'Epsilon'), ('d', ())), 0.0),
		])
	print grammar
	do(grammar, list("d"))
	do(grammar, list("ad"))
	do(grammar, list("abcd"))
	do(grammar, list("abbccd"))
	print "wrong:"
	do(grammar, list("abbbccd"))

	# Taken from: Boullier (1998), Generalization of Mildly
	# Context-Sensitive Formalisms.
	# Epsilon replaced with '|', added preterminal rules w/underscores
	print "the language { ww | w in {a,b}* }"
	print """initial trees:
(S (A Epsilon))
auxiliary trees:
(A a (A A*) a)
(A b (A A*) b)
(A (A A*))"""
	grammar = Grammar([
		((('ROOT', '_|'), ((0,),)), 0.0),
		((('ROOT', 'A', '_|'), ((0,1,0),)), 0.0),
		((('A', '_aa', 'A'), ((0,1), (0,1))), 0.0),
		((('A', '_bb', 'A'), ((0,1), (0,1))), 0.0),
		((('A', '_aa'), ((0,), (0,))), 0.0),
		((('A', '_bb'), ((0,), (0,))), 0.0),
		((('_aa', '_a', '_a'), ((0,),(1,))), 0.0),
		((('_bb', '_b', '_b'), ((0,),(1,))), 0.0),
		((('_a', 'Epsilon'), ('a', ())), 0.0),
		((('_b', 'Epsilon'), ('b', ())), 0.0),
		((('_|', 'Epsilon'), ('|', ())), 0.0),
		])
	print grammar
	do(grammar, list("a|a"))
	do(grammar, list("ab|ab"))
	do(grammar, list("abaab|abaab"))
	print "wrong:"
	do(grammar, list("a|b"))
	do(grammar, list("aa|bb"))

def dependencygrammar():
	""" An example dependency structure encoded in an LCFRS grammar.
	Taken from: Gildea (2011), Optimal Parsing Strategies for Linear
	Context-Free Rewriting Systems.
	Limitations:
		- rules have to be binarized
		- lexical rules have to be unary
	These have been dealt with by introducing nodes w/underscores.
	"""
	print "A dependency grammar in an LCFRS:"
	grammar = Grammar([
		((('NMOD', '_A'), ((0,),)), 0.0),
		((('SBJ','NMOD_hearing','PP'), ((0,), (1,))), 0.0),
		((('ROOT','SBJ','is_VC'),  ((0,1,0,1),)), 0.0),
		((('VC','_scheduled', 'TMP'), ((0,),(1,))), 0.0),
		((('PP','_on', 'NP'), ((0,1,),)), 0.0),
		((('NP','NMOD', '_issue'), ((0,1),)), 0.0),
		((('NMOD', '_the'), ((0,),)), 0.0),
		((('TMP', '_today'), ((0,),)), 0.0),
		((('is_VC', '_is', 'VC'), ((0,1), (1,))), 0.0),
		((('NMOD_hearing','NMOD', '_hearing'), ((0,1),)), 0.0),
		((('_A', 'Epsilon'), ('A', ())), 0.0),
		((('_hearing', 'Epsilon'), ('hearing', ())), 0.0),
		((('_is', 'Epsilon'), ('is', ())), 0.0),
		((('_scheduled', 'Epsilon'), ('scheduled', ())), 0.0),
		((('_on', 'Epsilon'), ('on', ())), 0.0),
		((('_the', 'Epsilon'), ('the', ())), 0.0),
		((('_issue', 'Epsilon'), ('issue', ())), 0.0),
		((('_today', 'Epsilon'), ('today', ())), 0.0)])
	print grammar
	testsent = "A hearing is scheduled on the issue today".split()
	do(grammar, testsent)

def bitext():
	print "bitext parsing with a synchronous CFG"
	trees = [Tree.parse(a, parse_leaf=int) for a in """\
	(ROOT (S (NP (NNP (John 0) (John 7))) (VP (VB (misses 1) (manque 5))\
     (PP (IN (a` 6)) (NP (NNP (Mary 2) (Mary 4)))))) (SEP (| 3)))
	(ROOT (S (NP (NNP (Mary 0) (Mary 4))) (VP (VB (likes 1) (aimes 5))\
     (NP (DT (la 6)) (NN (pizza 2) (pizza 7))))) (SEP (| 3)))""".splitlines()]
	sents = [["0"] * len(a.leaves()) for a in trees]
	map(treetransforms.binarize, trees)
	compiled_scfg = Grammar(grammar.induce_srcg(trees, sents))
	print "sentences:"
	for t in trees: print " ".join(w for _, w in sorted(t.pos()))
	print "treebank:"
	for t in trees: print t
	print compiled_scfg, "\n"

	print "correct translations:"
	do(compiled_scfg, ["0"] * 7,
		"John likes Mary | John aimes Mary".split())
	do(compiled_scfg, ["0"] * 9,
		u"John misses pizza | la pizza manque a` John".split())

	print "incorrect translations:"
	do(compiled_scfg, ["0"] * 7,
		"John likes Mary | Mary aimes John".split())
	do(compiled_scfg, ["0"] * 9,
		u"John misses pizza | John manque a` la pizza".split())

	# the following SCFG is taken from:
	# http://cdec-decoder.org/index.php?title=SCFG_translation
	# the grammar has been binarized and some new non-terminals had to be
	# introduced because terminals cannot appear in binary rules.
	lexicon = ("|", "ein", "ich", "Haus", "kleines", "grosses", "sah", "fand",
		"small", "little", "big", "large", "house", "shell", "a", "I", "the",
		"saw", "found")
	another_scfg = Grammar([
		((('ROOT','S', '_|'),  ((0,1,0),)), 0.0),
		((('S', 'NP', 'VP'), ((0,1), (0,1))), 0.2),
		((('DT', '_ein', '_a'), ((0,), (1,))), 0.5),
		((('NP', '_ich', '_I'), ((0,), (1,),)), 0.6),
		((('NP', 'DT', 'NP|<JJ-NN>'), ((0,1), (0,1))), 0.5),
		((('NP|<JJ-NN>', 'JJ', 'NN_house'), ((0,1), (0,1))), 0.1),
		((('NP|<JJ-NN>', 'JJ', 'NN_shell'), ((0,1), (0,1))), 1.3),
		((('NN_house', '_Haus', '_house'), ((0,), (1,))), 0.0),
		((('NN_shell', '_Haus', '_shell'), ((0,), (1,))), 0.0),
		((('JJ', '_kleines', '_small'), ((0,), (1,))), 0.1),
		((('JJ', '_kleines', '_little'), ((0,), (1,))), 0.9),
		((('JJ', '_grosses', '_big'), ((0,), (1,))), 0.8),
		((('JJ', '_grosses', '_large'), ((0,), (1,))), 0.2345),
		((('VP', 'V', 'NP'), ((0,1), (0,1))), 0.1),
		((('V', '_sah', '_saw'), ((0,), (1,))), 0.4),
		((('V', '_fand', '_found'), ((0,), (1,))), 0.4)
		] + [((('_%s' % word, 'Epsilon'), (word, ())), 0.0)
			for word in lexicon])
	print another_scfg
	do(another_scfg, "ich sah ein kleines Haus | I saw a small house".split())
	do(another_scfg, "ich sah ein kleines Haus | I saw a little house".split())
	do(another_scfg, "ich sah ein kleines Haus | I saw a small shell".split())
	do(another_scfg, "ich sah ein kleines Haus | I saw a little shell".split())

def do(compiledgrammar, testsent, testtags=None):
	chart, start, _ = plcfrs.parse(testsent,
		compiledgrammar,
		tags=testtags, start=compiledgrammar.toid["ROOT"],
		exhaustive=True)
	print "input:", " ".join("%d:%s" % a
			for a in enumerate(testtags if testtags else testsent)),
	if start:
		print
		results = kbest.lazykbest(chart, start, 10, compiledgrammar.tolabel)
		for tree, prob in results:
			tree = Tree(tree)
			treetransforms.unbinarize(tree)
			print exp(-prob), tree
	else:
		print "no parse!"
		#plcfrs.pprint_chart(chart, testsent, compiledgrammar.tolabel)
	print

def main():
	bitext()
	dependencygrammar()
	tree_adjoining_grammar()

if __name__=='__main__': main()