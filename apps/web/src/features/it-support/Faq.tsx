import { useEffect, useState, useCallback } from 'react';
import {
  Box,
  Typography,
  Paper,
  Accordion,
  AccordionSummary,
  AccordionDetails,
  Chip,
  Button,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  Alert,
  CircularProgress,
} from '@mui/material';
import { Add, ExpandMore } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface Faq {
  id: string;
  question: string;
  answer: string;
  category: string | null;
  sort_order: number;
  is_published: boolean;
}

export default function Faq() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [faqs, setFaqs] = useState<Faq[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [question, setQuestion] = useState('');
  const [answer, setAnswer] = useState('');
  const [category, setCategory] = useState('');
  const [sortOrder, setSortOrder] = useState('0');
  const [saving, setSaving] = useState(false);

  const [editFaq, setEditFaq] = useState<Faq | null>(null);
  const [editQuestion, setEditQuestion] = useState('');
  const [editAnswer, setEditAnswer] = useState('');
  const [editCategory, setEditCategory] = useState('');
  const [editSortOrder, setEditSortOrder] = useState('0');
  const [editPublished, setEditPublished] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, faqsRes] = await Promise.all([supabase.rpc('is_it_support'), supabase.rpc('get_faqs')]);
    setIsItSupport(Boolean(supportRes.data));
    if (faqsRes.error) setError(faqsRes.error.message);
    else setFaqs((faqsRes.data as Faq[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const createFaq = async () => {
    if (!question.trim() || !answer.trim()) return;
    setSaving(true);
    const { error } = await supabase.rpc('create_faq', {
      p_question: question,
      p_answer: answer,
      p_category: category || null,
      p_sort_order: Number(sortOrder) || 0,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    setQuestion('');
    setAnswer('');
    setCategory('');
    setSortOrder('0');
    load();
  };

  const openEdit = (f: Faq) => {
    setEditFaq(f);
    setEditQuestion(f.question);
    setEditAnswer(f.answer);
    setEditCategory(f.category ?? '');
    setEditSortOrder(String(f.sort_order));
    setEditPublished(f.is_published);
  };

  const saveEdit = async () => {
    if (!editFaq) return;
    setSaving(true);
    const { error } = await supabase.rpc('update_faq', {
      p_faq_id: editFaq.id,
      p_question: editQuestion,
      p_answer: editAnswer,
      p_category: editCategory || null,
      p_sort_order: Number(editSortOrder) || 0,
      p_is_published: editPublished,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditFaq(null);
    load();
  };

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">FAQ</Typography>
          <Typography variant="body2" color="text.secondary">
            Frequently asked questions for IT Support.
          </Typography>
        </Box>
        {isItSupport && (
          <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
            New FAQ
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      ) : faqs.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No FAQ entries yet.</Typography>
        </Paper>
      ) : (
        <Box>
          {faqs.map((f) => (
            <Accordion key={f.id}>
              <AccordionSummary expandIcon={<ExpandMore />}>
                <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                  <Typography>{f.question}</Typography>
                  {!f.is_published && <Chip size="small" label="Draft" />}
                  {f.category && <Chip size="small" variant="outlined" label={f.category} />}
                </Box>
              </AccordionSummary>
              <AccordionDetails>
                <Typography sx={{ whiteSpace: 'pre-wrap' }}>{f.answer}</Typography>
                {isItSupport && (
                  <Button size="small" sx={{ mt: 1 }} onClick={() => openEdit(f)}>
                    Edit
                  </Button>
                )}
              </AccordionDetails>
            </Accordion>
          ))}
        </Box>
      )}

      {/* New FAQ */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New FAQ</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Question" value={question} onChange={(e) => setQuestion(e.target.value)} fullWidth autoFocus />
          <TextField label="Answer" value={answer} onChange={(e) => setAnswer(e.target.value)} fullWidth multiline minRows={3} />
          <TextField label="Category" value={category} onChange={(e) => setCategory(e.target.value)} fullWidth />
          <TextField label="Sort order" type="number" value={sortOrder} onChange={(e) => setSortOrder(e.target.value)} fullWidth />
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createFaq} disabled={saving || !question.trim() || !answer.trim()}>
            {saving ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Edit FAQ */}
      <Dialog open={!!editFaq} onClose={() => setEditFaq(null)} fullWidth maxWidth="sm">
        <DialogTitle>Edit FAQ</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Question" value={editQuestion} onChange={(e) => setEditQuestion(e.target.value)} fullWidth autoFocus />
          <TextField label="Answer" value={editAnswer} onChange={(e) => setEditAnswer(e.target.value)} fullWidth multiline minRows={3} />
          <TextField label="Category" value={editCategory} onChange={(e) => setEditCategory(e.target.value)} fullWidth />
          <TextField label="Sort order" type="number" value={editSortOrder} onChange={(e) => setEditSortOrder(e.target.value)} fullWidth />
          <Button
            size="small"
            onClick={() => setEditPublished((p) => !p)}
            variant={editPublished ? 'contained' : 'outlined'}
            sx={{ alignSelf: 'flex-start' }}
          >
            {editPublished ? 'Published' : 'Draft'}
          </Button>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditFaq(null)}>Cancel</Button>
          <Button variant="contained" onClick={saveEdit} disabled={saving || !editQuestion.trim() || !editAnswer.trim()}>
            {saving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}