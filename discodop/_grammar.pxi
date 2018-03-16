""" Objects for grammars and grammar rules. """

# This regex should match exactly the set of valid yield functions,
# i.e., comma-separated strings of alternating occurrences from the set {0,1},
YFBINARY = re.compile(
		rb'^(?:0|1|1?(?:01)+|0?(?:10)+)(?:,(?:0|1|1?(?:01)+|0?(?:10)+))*$')
YFUNARYRE = re.compile(rb'^0(?:,0)*$')
# Match when non-integral weights are present
LCFRS_NONINT = re.compile(b'\t(?:0x)?[0-9]+[./][0-9]+(?:p-[0-9]+)?\n')
BITPAR_NONINT = re.compile(b'(?:^|\n)[0-9]+\.[0-9]+[ \t]')
LEXICON_NONINT = re.compile(b'[ \t][0-9]+[./][0-9]+[ \t\n]')
# Detect rule format of bitpar
BITPARRE = re.compile(rb'^[-.e0-9]+\b')
REMOVESTATESPLITS = re.compile(r'^([^\s|]+?)(?:\^[^\s|]*)?$')

# comparison functions for sorting rules on LHS/RHS labels.
cdef bool lt0(const ProbRule &a, const ProbRule &b) nogil:
	return a.no < b.no if a.lhs == b.lhs else a.lhs < b.lhs
cdef bool lt1(const ProbRule &a, const ProbRule &b) nogil:
	# sort unaries by rhs1 first, then by lhs, so that we can do
	# incremental binary search for the unaries of a given rhs1.
	return a.lhs < b.lhs if a.rhs1 == b.rhs1 else a.rhs1 < b.rhs1
cdef bool lt2(const ProbRule &a, const ProbRule &b) nogil:
	return a.prob < b.prob if a.rhs2 == b.rhs2 else a.rhs2 < b.rhs2


@cython.final
cdef class Grammar:
	"""A grammar object which stores rules compactly, indexed in various ways.

	:param rule_tuples_or_filename: either a sequence of tuples containing both
		phrasal & lexical rules, or the name of a file with the phrasal rules
		in text format; in the latter case the filename ``lexicon`` should be
		given. The text format allows for more efficient loading and is used
		internally.
	:param start: a string identifying the unique start symbol of this grammar,
		which will be used by default when parsing with this grammar
	:param altweights: a dictionary or filename with numpy arrays of
		alternative weights.

	By default the grammar is in logprob mode;
	invoke ``grammar.switch('default', logprob=False)`` to switch.
	If the grammar only contains integral weights (frequencies), they will
	be normalized into relative frequencies; if the grammar contains any
	non-integral weights, weights will be left unchanged."""
	def __init__(self, rule_tuples_or_filename, lexiconfile=None, start='ROOT',
			altweights=None, backtransform=None):
		self.start = start
		self.numunary = self.numbinary = self.numrules = 0
		self.maxfanout = 0
		self.logprob = True
		self.toid = StringIntDict()
		self.tolabel = StringList()
		if isinstance(altweights, dict):
			self.models = altweights
			self.altweightsfile = None
		elif altweights is not None:
			self.models = None
			self.altweightsfile = altweights
		else:
			self.models = {}
			self.altweightsfile = None
		self.backtransform = backtransform

		rules = lexicon = None
		if rule_tuples_or_filename and isinstance(rule_tuples_or_filename, str):
			if not isinstance(lexiconfile, str):
				raise ValueError('expected lexicon filename.')
			self.rulesfile = rule_tuples_or_filename
			self.lexiconfile = lexiconfile
			self.ruletuples = None
			rules = readbytes(rule_tuples_or_filename)
			lexicon = readbytes(lexiconfile)
			self.bitpar = BITPARRE.match(rules)
		elif rule_tuples_or_filename and isinstance(
				rule_tuples_or_filename[0], tuple):
			# convert tuples to strings with text format
			from .grammar import writegrammar
			self.rulesfile = self.lexiconfile = None
			self.ruletuples = rule_tuples_or_filename
			rules, lexicon = writegrammar(
					rule_tuples_or_filename, bitpar=False)
			rules, lexicon = rules.encode('utf8'), lexicon.encode('utf8')
			self.bitpar = False
		else:
			raise ValueError(
					'expected non-empty sequence of tuples or unicode string.'
					'got: %r' % type(rule_tuples_or_filename))

		# Epsilon gets ID 0, only occurs implicitly in RHS of lexical rules.
		Epsilon = b'Epsilon'
		root = self.start.encode('utf8')
		self.tblabelmapping = {self.start: [1]}
		self.toid.ob[Epsilon] = 0
		self.toid.ob[root] = 1
		self.tolabel.ob.push_back(Epsilon)
		self.tolabel.ob.push_back(root)
		self.freqmass.push_back(0)
		self.freqmass.push_back(0)
		self.fanout.push_back(0)
		self.fanout.push_back(1)
		self.addrules(rules, lexicon, init=True)
		del rules, lexicon

	def addrules(self, bytes rules, bytes lexicon, backtransform=None,
			init=False):
		"""Update weights and add new rules."""
		cdef int n
		cdef int orignumrules = self.numrules
		cdef int orignumbinary = self.numbinary
		cdef int orignumunary = self.numunary
		cdef int orignumlabels = self.tolabel.ob.size()
		if self._bylhs.size():  # drop sentinel rules
			self._bylhs.pop_back()
			self._unary.pop_back()
			self._lbinary.pop_back()
			self._rbinary.pop_back()
		self._convertrules(rules, backtransform)
		self._convertlexicon(lexicon, checkdup=init)
		self.nonterminals = self.toid.ob.size()

		if init:  # slightly faster way of normalizing than switch()
			for n in range(self.numrules):
				self._bylhs[n].prob = fabs(log(self._bylhs[n].prob
						/ self.freqmass[self._bylhs[n].lhs]))
			for n in range(self.numbinary):
				self._lbinary[n].prob = fabs(log(self._lbinary[n].prob
						/ self.freqmass[self._lbinary[n].lhs]))
			for n in range(self.numbinary):
				self._rbinary[n].prob = fabs(log(self._rbinary[n].prob
						/ self.freqmass[self._rbinary[n].lhs]))
			for n in range(self.numunary):
				self._unary[n].prob = fabs(log(self._unary[n].prob
						/ self.freqmass[self._unary[n].lhs]))
			for n in range(self.lexical.size()):
				self.lexical[n].prob = fabs(log(self.lexical[n].prob
						/ self.freqmass[self.lexical[n].lhs]))
			self.currentmodel = 'default'

		# store all non-lexical rules in a contiguous array
		# the other arrays will contain pointers to relevant parts thereof
		# (indexed on lhs, rhs1, and rhs2 of rules)
		self.bylhs.resize(self.nonterminals)
		self.unary.resize(self.nonterminals)
		self.lbinary.resize(self.nonterminals)
		self.rbinary.resize(self.nonterminals)
		self.bylhs[0] = &(self._bylhs[0])
		self.unary[0] = &(self._unary[0])
		self.lbinary[0] = &(self._lbinary[0])
		self.rbinary[0] = &(self._rbinary[0])

		# index & filter phrasal rules in different ways
		self._indexrules(self.bylhs, 0, 0, orignumrules)
		# check whether RHS labels occur as LHS of phrasal and/or lexical rule
		for lhs in range(1, self.nonterminals):
			if (self.bylhs[lhs][0].lhs != lhs and
					self.lexicalbylhs.find(lhs) == self.lexicalbylhs.end()):
				raise ValueError('symbol %r has not been seen as LHS '
					'in any rule.' % self.tolabel[lhs])
		self._indexrules(self.unary, 1, 2, orignumunary)
		self._indexrules(self.lbinary, 1, 3, orignumbinary)
		self._indexrules(self.rbinary, 2, 3, orignumbinary)

		# indexing requires sorting; this map gives the new index
		# given an original rule number (useful with the rulestr method).
		self.revrulemap.resize(self.numrules)
		for n in range(self.numrules):
			self.revrulemap[self._bylhs[n].no] = n

		if not init:  # updating of these weights not supported
			self.models = {}
			self.altweightsfile = None
			self.currentmodel = ''
			# ALL weights need to be re-normalized
			self.switch('default', self.logprob)

		# treebank label (NP) to list of matching grammar label IDs (NP^...)
		for n in range(orignumlabels, self.tolabel.ob.size()):
			strlabel = self.tolabel.ob[n].decode('utf8')
			match = REMOVESTATESPLITS.match(strlabel)
			if match is not None:
				self.tblabelmapping.setdefault(match.group(1), []).append(n)

	def _convertrules(self, bytes rules, list backtransform=None):
		"""Count unary & binary rules; make a canonical list of all
		non-terminal labels and assign them unique IDs."""
		cdef uint32_t n = self.numrules, m
		cdef uint32_t lineno = 0
		cdef Prob w
		cdef ProbRule cur
		cdef Rule key
		cdef string yf = b'<none>'
		cdef string weight
		cdef uint8_t fanout = 1, rhs1fanout = 1, rhs2fanout = 1
		cdef const char *buf = <const char*>rules
		cdef const char *prev
		cdef vector[string] fields
		cdef vector[string] rule
		while True:
			fields.clear()
			prev = buf
			buf = readfields(buf, fields)
			if buf is NULL:
				break
			elif fields.size() == 0:
				continue
			if self.bitpar:
				weight = fields[0]
				fields.erase(fields.begin())
				rule = fields
				# NB: leave yf at b'<none>'
				if rule.size() > 1:
					cur.args, cur.lengths = 0b10, 0b10
				else:
					cur.args, cur.lengths = 0b0, 0b1
			else:
				weight = fields[fields.size() - 1]
				yf = fields[fields.size() - 2]
				fields.pop_back()
				fields.pop_back()
				rule = fields
				cur.lengths = cur.args = m = 0
				fanout = 1
				rhs1fanout = rhs2fanout = 0
				for a in yf:
					if a == b',':
						cur.lengths |= 1 << (m - 1)
						fanout += 1
						continue
					elif a == b'0':
						rhs1fanout += 1
					elif a == b'1':
						cur.args += 1 << m
						rhs2fanout += 1
					else:
						raise ValueError('invalid symbol in yield function: %r'
								' (not in set [01,])\n%r' % (
								a, prev[:buf - prev].decode('utf8')))
					m += 1
				cur.lengths |= 1 << (m - 1)
				if m >= (8 * sizeof(cur.args)):
					raise ValueError(
							'Parsing complexity (%d) too high (max %d).\n'
							'Rule: %r' % (m, (8 * sizeof(cur.args)),
							prev[:buf - prev].decode('utf8')))
				if rule.size() == 2:
					# if not YFUNARYRE.match(yf):
					if rhs1fanout == 0 or rhs2fanout != 0:
						raise ValueError('expected unary yield function: '
								'%r\t%r' % (yf, rule))
				elif rule.size() == 3:
					# if not YFBINARY.match(yf):
					if rhs1fanout == 0 or rhs2fanout == 0:
						raise ValueError('expected binary yield function: '
								'%r\t%r' % (yf, rule))
					# if b'0' not in yf or b'1' not in yf:
					# 	raise ValueError('mismatch between non-terminals and '
					# 			'yield function: %r' %
					# 			prev[:buf - prev].decode('utf8'))
			it = self.toid.ob.find(rule[0])
			if it == self.toid.ob.end():
				cur.lhs = self.toid.ob[rule[0]] = self.tolabel.ob.size()
				self.tolabel.ob.push_back(rule[0])
				self.freqmass.push_back(0)
				self.fanout.push_back(fanout)
				if fanout > self.maxfanout:
					self.maxfanout = fanout
			else:
				cur.lhs = dereference(it).second
				if self.fanout[cur.lhs] != fanout:
					raise ValueError("conflicting fanouts for symbol "
						"%r.\nprevious: %d; this non-terminal: %d. rule:\n%r"
						% (rule[0], self.fanout[cur.lhs], fanout,
						prev[:buf - prev].decode('utf8')))
			it = self.toid.ob.find(rule[1])
			if it == self.toid.ob.end():
				cur.rhs1 = self.toid.ob[rule[1]] = self.tolabel.ob.size()
				self.tolabel.ob.push_back(rule[1])
				self.freqmass.push_back(0)
				self.fanout.push_back(rhs1fanout)
				if rhs1fanout > self.maxfanout:
					self.maxfanout = rhs1fanout
			else:
				cur.rhs1 = dereference(it).second
			if cur.lhs == 0 or cur.rhs1 == 0:
				raise ValueError('Epsilon symbol may only occur '
						'in RHS of lexical rules:\n%r' %
						prev[:buf - prev].decode('utf8'))
			if rule.size() == 2:
				cur.rhs2 = 0
			elif rule.size() == 3:
				it = self.toid.ob.find(rule[2])
				if it == self.toid.ob.end():
					cur.rhs2 = self.toid.ob[rule[2]] = self.tolabel.ob.size()
					self.tolabel.ob.push_back(rule[2])
					self.freqmass.push_back(0)
					self.fanout.push_back(rhs2fanout)
					if rhs2fanout > self.maxfanout:
						self.maxfanout = rhs2fanout
				else:
					cur.rhs2 = dereference(it).second
				if cur.rhs2 == 0:
					raise ValueError('Epsilon symbol may only occur '
							'in RHS of lexical rules:\n%r'
						% prev[:buf - prev].decode('utf8'))
			elif rule.size() < 2:
				raise ValueError('Not enough nonterminals:\n%r'
						% prev[:buf - prev].decode('utf8'))
			else:
				raise ValueError('Grammar not binarized:\n%r\n%r'
						% (list(rule), prev[:buf - prev].decode('utf8')))
			if cur.rhs1 == 1 or cur.rhs2 == 1:
				raise ValueError('Start symbol should only occur on LHS:\n%r'
						% prev[:buf - prev].decode('utf8'))
			w = convertweight(weight.c_str())
			if w <= 0:
				raise ValueError('Expected positive non-zero weight\n%r'
						% prev[:buf - prev].decode('utf8'))
			key.lhs, key.rhs1, key.rhs2 = cur.lhs, cur.rhs1, cur.rhs2
			key.args, key.lengths = cur.args, cur.lengths
			it1 = self.rulenos.find(key)
			if it1 == self.rulenos.end():  # add new rule
				self.rulenos[key] = n
				cur.no = n
				cur.prob = w  # fabs(log(w))
				self.rulecounts.push_back(w)
				self._bylhs.push_back(cur)
				if backtransform is not None and lineno < len(backtransform):
					# new fragments come AFTER rules without fragments,
					# so a gap is created; either fill gap [below],
					# or re-order previous rules,
					# FIXME: or use hashtable / sparsetable for backtransform.
					if len(self.backtransform) != n:
						self.backtransform.extend(
								[None] * (n - len(self.backtransform)))
					self.backtransform.append(backtransform[lineno])
				if rule.size() == 2:
					self.numunary += 1
					self._unary.push_back(cur)
				elif rule.size() == 3:
					self.numbinary += 1
					self._lbinary.push_back(cur)
					self._rbinary.push_back(cur)
				n += 1
			else:  # update weight of existing rule
				m = dereference(it1).second
				self.rulecounts[m] += w
			self.freqmass[cur.lhs] += w
			lineno += 1

		self.numrules = self.numunary + self.numbinary
		self.phrasalnonterminals = self.toid.ob.size()
		# sentinel rules
		cur.lhs = cur.rhs1 = cur.rhs2 = cur.prob = cur.lengths = cur.args = 0
		self._bylhs.push_back(cur)
		self._unary.push_back(cur)
		self._lbinary.push_back(cur)
		self._rbinary.push_back(cur)
		if not self.numrules:
			raise ValueError('No rules found')

	def _convertlexicon(self, bytes lexicon, bint checkdup=True):
		"""Make objects for lexical rules."""
		cdef int x
		cdef Prob w
		cdef const char *buf = <const char*>lexicon
		cdef const char *prev
		cdef vector[string] fields
		cdef string tag, weight
		cdef string word
		cdef LexicalRule lexrule
		cdef uint32_t lexruleno

		while True:
			fields.clear()
			prev = buf
			buf = readfields(buf, fields)
			if buf is NULL:
				break
			elif fields.size() == 0:
				continue
			elif fields.size() == 1:
				raise ValueError('Expected: word<TAB>tag1<SPACE>weight1...'
						'Got: %r' % prev[:buf - prev].decode('utf8'))
			word = fields[0]
			if (checkdup and self.lexicalbyword.find(word)
					!= self.lexicalbyword.end()):
				raise ValueError('word %r appears more than once '
						'in lexicon file' % unescape(word.decode('utf8')))
			for n in range(1, fields.size()):
				x = fields[n].find_first_of(ord(b' '))
				if x > fields[n].size():
					raise ValueError('Expected: word<TAB>tag1<SPACE>weight1'
							'<TAB>tag2<SPACE>weight2...\n'
							'Got: %r' % prev[:buf - prev].decode('utf8'))
				tag = string(fields[n].c_str(), x)
				weight = string(fields[n].c_str() + x + 1)
				it = self.toid.ob.find(tag)
				if it == self.toid.ob.end():
					lexrule.lhs = self.toid.ob[tag] = self.tolabel.ob.size()
					self.tolabel.ob.push_back(tag)
					self.freqmass.push_back(0)
					self.fanout.push_back(1)
					# disabled because we add ids for labels on the fly:
					# logging.warning('POS tag %r for word %r not used in any '
					# 		'phrasal rule', tag, word.decode('utf8'))
					# continue
				else:
					lexrule.lhs = dereference(it).second
					if self.fanout[lexrule.lhs] != 1:
						raise ValueError('POS tag %r has fan-out %d, may only'
								' be 1.' % (self.fanout[lexrule.lhs], tag))
				w = convertweight(weight.c_str())
				if w <= 0:
					raise ValueError('weights should be positive '
							'and non-zero:\n%r'
							% prev[:buf - prev].decode('utf8'))
				it1 = self.lexicalbylhs[lexrule.lhs].find(word)
				if it1 == self.lexicalbylhs[lexrule.lhs].end():  # new rule
					lexruleno = self.lexical.size()
					lexrule.prob = w  # fabs(log(w))
					self.lexcounts.push_back(w)
					self.lexical.push_back(lexrule)
					self.lexicalbyword[word].push_back(lexruleno)
					self.lexicalbylhs[lexrule.lhs][word] = lexruleno
				else:  # update weight
					lexruleno = dereference(it1).second
					self.lexcounts[lexruleno] += w
				self.freqmass[lexrule.lhs] += w
			if self.lexical.size() == 0:
				raise ValueError('no lexical rules found.')

	cdef _indexrules(Grammar self, vector[ProbRule *]& dest, int idx,
			int filterlen, int orignumrules):
		"""Auxiliary function to create Grammar objects. Copies certain
		grammar rules and sorts them on the given index.
		Resulting array is ordered by lhs, rhs1, or rhs2 depending on the value
		of `idx` (0, 1, or 2); filterlen can be 0, 2, or 3 to get all, only
		unary, or only binary rules, respectively.
		A separate array has a pointer for each non-terminal into this array;
		e.g.: dest[NP][0] == the first rule with an NP in the idx position."""
		cdef uint32_t prev = self.nonterminals, idxlabel = 0, n, m = 0
		cdef ProbRule *cur
		cdef vector[ProbRule].iterator first
		# need to set dest even when there are no rules for that idx
		for n in range(1, self.nonterminals):
			dest[n] = dest[0]
		# sort rules by idx (NB: ensure stable sort w/appropriate cmp func)
		if idx == 0:
			cmpfun = lt0
			m = self.numrules
			first = self._bylhs.begin()
		elif idx == 1:
			cmpfun = lt1
			if filterlen == 2:
				m = self.numunary
				first = self._unary.begin()
			else:
				m = self.numbinary
				first = self._lbinary.begin()
		else:  # idx == 2:
			cmpfun = lt2
			m = self.numbinary
			first = self._rbinary.begin()
		# sort the new rules
		stdsort(first + orignumrules, first + m, cmpfun)
		# merge sorted old rules with sorted new rules
		inplace_merge(first, first + orignumrules, first + m, cmpfun)
		# make index: dest[NP] points to first rule with NP in index position
		for n in range(m):
			cur = &(dest[0][n])
			if idx == 0:
				idxlabel = cur.lhs
			elif idx == 1:
				idxlabel = cur.rhs1
			elif idx == 2:
				idxlabel = cur.rhs2
			if idxlabel != prev:
				dest[idxlabel] = cur
			prev = idxlabel
			assert cur.no < self.numrules
		# sentinel rule
		dest[0][m].lhs = dest[0][m].rhs1 = dest[0][m].rhs2 = self.nonterminals

	def switch(self, str name, bint logprob=True):
		cdef int n
		cdef Prob *tmp
		cdef Prob [:] ob
		cdef size_t numweights = self.numrules + self.lexical.size()
		if self.currentmodel == name and self.logprob == logprob:
			return
		if name == 'default':  # normalize
			if logprob:
				for n in range(self.numrules):
					self._bylhs[n].prob = fabs(log(
							self.rulecounts[self._bylhs[n].no]
							/ self.freqmass[self._bylhs[n].lhs]))
				for n in range(self.lexical.size()):
					self.lexical[n].prob = fabs(log(self.lexcounts[n]
							/ self.freqmass[self.lexical[n].lhs]))
			else:
				for n in range(self.numrules):
					self._bylhs[n].prob = (
							self.rulecounts[self._bylhs[n].no]
							/ self.freqmass[self._bylhs[n].lhs])
				for n in range(self.lexical.size()):
					self.lexical[n].prob = (self.lexcounts[n]
							/ self.freqmass[self.lexical[n].lhs])
			# instead of copying weights from bylhs, could compute them
			# again, but number of lookups is the same.
			for n in range(self.numbinary):
				self._lbinary[n].prob = self._bylhs[
						self.revrulemap[self._lbinary[n].no]].prob
			for n in range(self.numbinary):
				self._rbinary[n].prob = self._bylhs[
						self.revrulemap[self._rbinary[n].no]].prob
			for n in range(self.numunary):
				self._unary[n].prob = self._bylhs[
						self.revrulemap[self._unary[n].no]].prob
		else:
			if self.models is None and self.altweightsfile:
				self.models = np.load(self.altweightsfile)  # FIXME: keep open?
			model = self.models[name]
			if len(model) != <signed>numweights:
				raise ValueError('length mismatch: %d grammar rules, '
						'%d weights given.' % (
						self.numrules + self.lexical.size(), len(model)))
			ob = np.abs(np.log(model)) if logprob else model
			tmp = &(ob[0])
			for n in range(self.numrules):
				self._bylhs[n].prob = tmp[self._bylhs[n].no]
			for n in range(self.numbinary):
				self._lbinary[n].prob = tmp[self._lbinary[n].no]
			for n in range(self.numbinary):
				self._rbinary[n].prob = tmp[self._rbinary[n].no]
			for n in range(self.numunary):
				self._unary[n].prob = tmp[self._unary[n].no]
			for n in range(self.lexical.size()):
				self.lexical[n].prob = tmp[self.numrules + n]
		self.logprob = logprob
		self.currentmodel = name

	def setmask(self, seq):
		"""Given a sequence of rule numbers, store a mask so that any phrasal
		rules not in the sequence are deactivated. If sequence is None, the
		mask is cleared (all rules are active)."""
		cdef int n
		self.mask.resize(0)
		# zero-bit = not blocked or out of range; 1-bit = blocked.
		if seq is None:
			return
		self.mask.resize(BITNSLOTS(self.numrules), ~(<uint64_t>0))
		for n in seq:
			CLEARBIT(&(self.mask[0]), n)

	def testgrammar(self, epsilon=1e-16):
		"""Test whether all left-hand sides sum to 1 +/-epsilon for the
		currently selected weights."""
		cdef ProbRule *rule
		cdef LexicalRule lexrule
		cdef uint32_t n, maxlabel = 0
		cdef size_t numweights = self.numrules + self.lexical.size()
		cdef list weights = [[] for _ in range(self.nonterminals)]
		cdef Prob [:] tmp
		if self.currentmodel == 'default':
			tmp = clone(dblarray, numweights, False)
			for n in range(self.numrules):
				tmp[n] = (self.rulecounts[n]
						/ self.freqmass[self._bylhs[self.revrulemap[n]].lhs])
			for n in range(self.lexical.size()):
				tmp[self.numrules + n] = (self.lexcounts[n]
						/ self.freqmass[self.lexical[n].lhs])
		else:
			tmp = self.models[self.currentmodel]
		# We could be strict about separating POS tags and phrasal categories,
		# but Negra contains at least one tag (--) used for both.
		for n in range(self.numrules):
			rule = &(self._bylhs[n])
			weights[rule.lhs].append(tmp[rule.no])
		n = self.numrules
		for lexrule in self.lexical:
			weights[lexrule.lhs].append(tmp[n])
			n += 1
		maxdiff = epsilon
		for lhs, lhsweights in enumerate(weights[1:], 1):
			mass = fsum(lhsweights)
			if abs(mass - 1.0) > maxdiff:
				maxdiff = abs(mass - 1.0)
				maxlabel = lhs
		if maxdiff > epsilon:
			msg = ('Weights do not sum to 1 +/- %g.\n'
					'Largest difference with rules for LHS \'%s\': '
					'sum = %g; diff = %g' % (
					epsilon, self.tolabel[maxlabel],
					fsum(weights[maxlabel]), maxdiff))
			return False, msg
		return True, 'All left hand sides sum to 1 +/- epsilon=%s' % epsilon

	def getmapping(Grammar self, Grammar coarse, striplabelre=None,
			neverblockre=None, bint splitprune=False, bint markorigin=False,
			dict mapping=None, int startidx=0, bint debug=True):
		"""Construct mapping of this grammar's non-terminal labels to another.

		:param coarse: the grammar to which this grammar's labels will be
			mapped. May be ``None`` to establish a separate mapping to own
			labels.
		:param striplabelre: if not None, a compiled regex used to form
			the coarse label for a given fine label. This regex is applied
			with a substitution to the empty string.
		:param neverblockre: labels that match this regex will never be pruned.
			Also used to identify auxiliary labels of Double-DOP grammars.

			- use ``|<`` to ignore nodes introduced by binarization;
				useful if coarse and fine stages employ different kinds of
				markovization; e.g., ``NP`` and ``VP`` may be blocked,
				but not ``NP|<DT-NN>``.
			- ``_[0-9]+`` to ignore discontinuous nodes ``X_n`` where ``X`` is
				a label and *n* is a fanout.

		:param mapping: a dictionary with strings of fine labels mapped to
			coarse labels. striplabelre, if given, is applied first.
		:param startidx: when running getmapping after new rules have been
			added, pass the value of grammar.nonterminals before they were
			added to avoid rebuilding the mapping completely.
		:param debug: whether to return a debug message.

		The regexes should be compiled objects, i.e., ``re.compile(regex)``,
		or ``None`` to leave labels unchanged.
		"""
		cdef bint selfmap = coarse is None
		cdef int n, m
		cdef set seen = {0}
		cdef vector[Label] result
		result.swap(self.selfmapping if selfmap else self.mapping)
		result.resize(self.nonterminals)
		if selfmap:
			coarse = self
		else:
			# construct mapping from coarse label to fine labels
			self.revmap.resize(coarse.nonterminals)
		if splitprune and markorigin:
			self.splitmapping.resize(self.nonterminals)
		for n in range(startidx, self.nonterminals):
			strlabel = self.tolabel.ob[n].decode('utf8')
			if not neverblockre or neverblockre.search(strlabel) is None:
				if striplabelre is not None:
					strlabel = striplabelre.sub('', strlabel, 1)
				if mapping is not None:
					strlabel = mapping[strlabel]
				if self.fanout[n] > 1 and splitprune:
					strlabel += '*'
				if self.fanout[n] > 1 and splitprune and markorigin:
					result[n] = self.nonterminals  # sentinel value
					self.splitmapping[n].resize(self.fanout[n])
					for m in range(self.fanout[n]):
						self.splitmapping[n][m] = coarse.toid[
								strlabel + str(m)]
						seen.add(self.splitmapping[n][m])
						if not selfmap:
							self.revmap[self.splitmapping[n][m]].push_back(n)
				else:
					try:
						result[n] = coarse.toid[strlabel]
						if not selfmap:
							self.revmap[result[n]].push_back(n)
					except KeyError:
						raise KeyError('incorrect mapping; '
								'coarse label %s not found, mapped from %s' % (
								strlabel, self.tolabel[n]))
			else:
				result[n] = 0
		if startidx != 0 or not debug:
			msg = ''
		elif seen == set(range(coarse.nonterminals)):
			msg = 'label sets are equal'
		else:
			# NB: ALL fine symbols are mapped to some coarse symbol;
			# we only check if all coarse symbols have received a mapping.
			l = sorted([coarse.tolabel[a] for a in
					set(range(coarse.nonterminals)) - seen])
			diff = ', '.join(l[:10]) + (', ...' if len(l) > 10 else '')
			if coarse.nonterminals > self.nonterminals:
				msg = ('grammar is not a superset of coarse grammar:\n'
						'coarse labels without mapping: { %s }' % diff)
			elif coarse.nonterminals < self.nonterminals:
				msg = 'grammar is a proper superset of coarse grammar.'
			else:
				msg = ('equal number of nodes, but not equivalent:\n'
						'coarse labels without mapping: { %s }' % diff)
		if selfmap:
			self.selfmapping.swap(result)
		else:
			self.mapping.swap(result)
		return msg

	def getrulemapping(Grammar self, Grammar coarse, striplabelre):
		"""Produce a mapping of coarse rules to sets of fine rules.

		A coarse rule for a given fine rule is found by applying the label
		mapping to rules. The rule mapping uses the rule numbers (``rule.no``)
		derived from the original order of the rules when the Grammar object
		was created; e.g., ``self.rulemapping[12] == [34, 56, 78, ...]``
		where 12 refers to a rule in the given coarse grammar, and the other
		IDs to rules in this grammar."""
		cdef int n, m
		cdef ProbRule *rule
		cdef Rule key
		cdef list rulemapping = [array('L') for _ in range(coarse.numrules)]
		for n in range(self.numrules):
			rule = &(self._bylhs[n])
			# this could work, but only if mapping[..] is never 0.
			# key.lhs = self.mapping[rule.lhs]
			# key.rhs1 = self.mapping[rule.rhs1]
			# key.rhs2 = self.mapping[rule.rhs2]
			key.lhs = coarse.toid[striplabelre.sub(
					'', self.tolabel[rule.lhs], 1)]
			key.rhs1 = coarse.toid[striplabelre.sub(
					'', self.tolabel[rule.rhs1], 1)]
			key.rhs2 = coarse.toid[striplabelre.sub(
					'', self.tolabel[rule.rhs2], 1)]
			key.args, key.lengths = rule.args, rule.lengths
			m = coarse.rulenos[key]
			rulemapping[m].append(rule.no)
		if self is coarse:
			self.selfrulemapping = rulemapping
		else:
			self.rulemapping = rulemapping

	cpdef noderuleno(self, node):
		"""Get rule no given a node of a continuous tree."""
		cdef Rule key
		key.lhs = self.toid.ob[node.label.encode('utf8')]
		key.rhs1 = self.toid.ob[node[0].label.encode('utf8')]
		if len(node) > 1:
			key.rhs2 = self.toid.ob[node[1].label.encode('utf8')]
			key.args, key.lengths = 0b10, 0b10
		else:
			key.rhs2 = 0
			key.args, key.lengths = 0b0, 0b1
		return self.rulenos[key]

	cpdef getruleno(self, tuple r, tuple yf):
		"""Get rule no given a (discontinuous) production."""
		cdef Rule key
		cdef bytes lhs = r[0].encode('utf8')
		cdef bytes rhs1 = r[1].encode('utf8')
		key.lhs, key.rhs1 = self.toid.ob[lhs], self.toid.ob[rhs1]
		key.rhs2 = self.toid.ob[r[2].encode('utf8')] if len(r) > 2 else 0
		getyf(yf, &key.args, &key.lengths)
		return self.rulenos[key]

	def incrementrulecount(self, int ruleno, int freq):
		"""Add freq to observed count of a rule.
		NB: need to re-normalize after this; alternative weights not affected.
		"""
		self.rulecounts[ruleno] += freq

	cpdef rulestr(self, int n):
		"""Return a string representation of a specific rule in this grammar."""
		cdef ProbRule rule
		if not 0 <= n < self.numrules:
			raise ValueError('Out of range: %s' % n)
		rule = self._bylhs[n]
		left = '%.4f %s => %s%s' % (
			exp(-rule.prob) if self.logprob else rule.prob,
			self.tolabel[rule.lhs], self.tolabel[rule.rhs1],
			' %s' % self.tolabel[rule.rhs2] if rule.rhs2 else '')
		return '%s %s %g/%g [%d]' % (
				left.ljust(40), self.yfstr(rule).ljust(2),
				self.rulecounts[rule.no], self.freqmass[rule.lhs], rule.no)

	cdef yfstr(self, ProbRule rule):
		cdef int n, m = 0
		cdef str result = ''
		for n in range(8 * sizeof(rule.args)):
			result += '1' if (rule.args >> n) & 1 else '0'
			if (rule.lengths >> n) & 1:
				m += 1
				if m == self.fanout[rule.lhs]:
					return result
				else:
					result += ','
		raise ValueError('illegal yield function; expected %d components.\n'
				'args: %s; lengths: %s' % (self.fanout[rule.lhs],
				bin(rule.args), bin(rule.lengths)))

	def getpos(self):
		"""Return POS tags in lexicon as list."""
		return [self.tolabel.ob[it.first].decode('utf8')
				for it in self.lexicalbylhs]

	def getwords(self):
		"""Return words in lexicon as list."""
		return [x.first.decode('utf8') for x in self.lexicalbyword]

	def getlexprobs(self, str word):
		"""Return a list of probabilities for a word."""
		it = self.lexicalbyword.find(word.encode('utf8'))
		if it == self.lexicalbyword.end():
			return []
		return [self.lexical[n].prob for n in dereference(it).second]

	def __str__(self):
		rules = '\n'.join(filter(None,
			[self.rulestr(n) for n in range(self.numrules)]))
		lexical = '\n'.join(['%.2f %s => %s' % (
				exp(-self.lexical[n].prob) if self.logprob
				else self.lexical[n].prob,
				self.tolabel[self.lexical[n].lhs],
				word.decode('utf8'))
			for word in sorted([x.first for x in self.lexicalbyword])
			for n in sorted([y for y in self.lexicalbyword[word]],
			key=lambda n: self.lexical[n].lhs)])
		labels = ', '.join(['%s=%d %d' % (
				a, self.toid[a], self.fanout[self.toid[a]])
				for a in sorted(self.toid)])
		return 'rules:\n%s\nlexicon:\n%s\nlabels:\n%s' % (
				rules, lexical, labels)

	def __repr__(self):
		return '%s(\n%r,\n%r\n)' % (self.__class__.__name__,
				self.rulesfile or self.ruletuples, self.lexiconfile)

	def __reduce__(self):
		"""Helper function for pickling."""
		return (Grammar, (self.rulesfile or self.ruletuples, self.lexiconfile,
				self.start, self.altweightsfile or self.models))


cdef inline Prob convertweight(const char *weight):
	"""Convert weight to float/double; weight may be a fraction '1/2'
	(returns only first part of fraction), decimal float '0.5',
	or hex float '0x1.0p-1'. Returns 0 on error."""
	cdef char *endptr = NULL
	cdef Prob w = strtod(weight, &endptr)
	if endptr[0] == b'/':  # allow for compatibility
		pass  # w /= strtod(&endptr[1], NULL)
	elif endptr[0]:
		return 0
	return w


cdef inline const char *readfields(const char *buf, vector[string] &result):
	"""Tokenize a tab-separated line in a string.

	:returns: a pointer of the new position in buf,
		or NULL if end of string was reached.
		result is extended with the tokens encountered."""
	cdef const char *endofline = strchr(buf, b'\n')
	cdef const char *tmp
	if endofline is NULL:
		# NB: if last last line has no end of line, its tokens will be ignored.
		return NULL
	tmp = strchr(buf, b'\t')
	while tmp is not NULL and tmp < endofline:
		result.push_back(string(buf, tmp - buf))
		buf = tmp + 1
		tmp = strchr(buf, b'\t')
	result.push_back(string(buf, endofline - buf))
	return endofline + 1
