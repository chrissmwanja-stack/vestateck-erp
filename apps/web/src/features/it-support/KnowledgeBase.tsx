import { useEffect, useState, useCallback } from 'react';
import {
  Box,
  Typography,
  Paper,
  List,
  ListItemButton,
  ListItemText,
  Chip,
  Button,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  Alert,
  CircularProgress,
  Divider,
  InputAdornment,
} from '@mui/material';
import { Add, Search } from '@mui/icons-material';
import { supabase } from '../../lib/supabaseClient';

interface Article {
  id: string;
  title: string;
  category: string | null;
  content: string;
  is_published: boolean;
  updated_at: string;
}

export default function KnowledgeBase() {
  const [isItSupport, setIsItSupport] = useState(false);
  const [articles, setArticles] = useState<Article[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<Article | null>(null);

  const [newOpen, setNewOpen] = useState(false);
  const [title, setTitle] = useState('');
  const [category, setCategory] = useState('');
  const [content, setContent] = useState('');
  const [isPublished, setIsPublished] = useState(true);
  const [saving, setSaving] = useState(false);

  const [editOpen, setEditOpen] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const [supportRes, articlesRes] = await Promise.all([
      supabase.rpc('is_it_support'),
      supabase.rpc('get_kb_articles'),
    ]);
    setIsItSupport(Boolean(supportRes.data));
    if (articlesRes.error) setError(articlesRes.error.message);
    else setArticles((articlesRes.data as Article[]) ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const resetNewForm = () => {
    setTitle('');
    setCategory('');
    setContent('');
    setIsPublished(true);
  };

  const createArticle = async () => {
    if (!title.trim() || !content.trim()) return;
    setSaving(true);
    const { error } = await supabase.rpc('create_kb_article', {
      p_title: title,
      p_content: content,
      p_category: category || undefined,
      p_is_published: isPublished,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setNewOpen(false);
    resetNewForm();
    load();
  };

  const openEdit = (article: Article) => {
    setSelected(article);
    setTitle(article.title);
    setCategory(article.category ?? '');
    setContent(article.content);
    setIsPublished(article.is_published);
    setEditOpen(true);
  };

  const saveEdit = async () => {
    if (!selected) return;
    setSaving(true);
    const { error } = await supabase.rpc('update_kb_article', {
      p_article_id: selected.id,
      p_title: title,
      p_content: content,
      p_category: category || undefined,
      p_is_published: isPublished,
    });
    setSaving(false);
    if (error) {
      setError(error.message);
      return;
    }
    setEditOpen(false);
    setSelected(null);
    load();
  };

  const filtered = articles.filter(
    (a) =>
      !search ||
      a.title.toLowerCase().includes(search.toLowerCase()) ||
      (a.category ?? '').toLowerCase().includes(search.toLowerCase())
  );

  return (
    <Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 2 }}>
        <Box>
          <Typography variant="h5">Knowledge Base</Typography>
          <Typography variant="body2" color="text.secondary">
            How-to guides and reference articles for common IT issues.
          </Typography>
        </Box>
        {isItSupport && (
          <Button variant="contained" startIcon={<Add />} onClick={() => setNewOpen(true)}>
            New article
          </Button>
        )}
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <TextField
        size="small"
        placeholder="Search articles…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        sx={{ mb: 2, width: 320 }}
        InputProps={{
          startAdornment: (
            <InputAdornment position="start">
              <Search fontSize="small" />
            </InputAdornment>
          ),
        }}
      />

      {loading ? (
        <Box sx={{ display: 'flex', justifyContent: 'center', py: 6 }}>
          <CircularProgress />
        </Box>
      ) : filtered.length === 0 ? (
        <Paper sx={{ p: 4, textAlign: 'center' }}>
          <Typography color="text.secondary">No articles found.</Typography>
        </Paper>
      ) : (
        <Paper>
          <List disablePadding>
            {filtered.map((a, i) => (
              <Box key={a.id}>
                {i > 0 && <Divider />}
                <ListItemButton onClick={() => setSelected(a)} sx={{ py: 1.5 }}>
                  <ListItemText
                    primary={
                      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                        <Typography variant="subtitle1">{a.title}</Typography>
                        {!a.is_published && <Chip size="small" label="Draft" />}
                        {a.category && <Chip size="small" variant="outlined" label={a.category} />}
                      </Box>
                    }
                    secondary={`Updated ${new Date(a.updated_at).toLocaleDateString()}`}
                  />
                </ListItemButton>
              </Box>
            ))}
          </List>
        </Paper>
      )}

      {/* View article */}
      <Dialog open={!!selected && !editOpen} onClose={() => setSelected(null)} fullWidth maxWidth="md">
        {selected && (
          <>
            <DialogTitle sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              {selected.title}
              {selected.category && <Chip size="small" label={selected.category} />}
            </DialogTitle>
            <DialogContent>
              <Typography variant="body1" sx={{ whiteSpace: 'pre-wrap' }}>
                {selected.content}
              </Typography>
            </DialogContent>
            <DialogActions>
              {isItSupport && <Button onClick={() => openEdit(selected)}>Edit</Button>}
              <Button onClick={() => setSelected(null)}>Close</Button>
            </DialogActions>
          </>
        )}
      </Dialog>

      {/* New article */}
      <Dialog open={newOpen} onClose={() => setNewOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>New article</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Title" value={title} onChange={(e) => setTitle(e.target.value)} fullWidth autoFocus />
          <TextField label="Category" value={category} onChange={(e) => setCategory(e.target.value)} fullWidth />
          <TextField label="Content" value={content} onChange={(e) => setContent(e.target.value)} fullWidth multiline minRows={6} />
          <Button
            size="small"
            onClick={() => setIsPublished((p) => !p)}
            variant={isPublished ? 'contained' : 'outlined'}
            sx={{ alignSelf: 'flex-start' }}
          >
            {isPublished ? 'Published' : 'Draft'}
          </Button>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setNewOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={createArticle} disabled={saving || !title.trim() || !content.trim()}>
            {saving ? 'Creating…' : 'Create'}
          </Button>
        </DialogActions>
      </Dialog>

      {/* Edit article */}
      <Dialog open={editOpen} onClose={() => setEditOpen(false)} fullWidth maxWidth="sm">
        <DialogTitle>Edit article</DialogTitle>
        <DialogContent sx={{ display: 'flex', flexDirection: 'column', gap: 2, mt: 1 }}>
          <TextField label="Title" value={title} onChange={(e) => setTitle(e.target.value)} fullWidth autoFocus />
          <TextField label="Category" value={category} onChange={(e) => setCategory(e.target.value)} fullWidth />
          <TextField label="Content" value={content} onChange={(e) => setContent(e.target.value)} fullWidth multiline minRows={6} />
          <Button
            size="small"
            onClick={() => setIsPublished((p) => !p)}
            variant={isPublished ? 'contained' : 'outlined'}
            sx={{ alignSelf: 'flex-start' }}
          >
            {isPublished ? 'Published' : 'Draft'}
          </Button>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setEditOpen(false)}>Cancel</Button>
          <Button variant="contained" onClick={saveEdit} disabled={saving || !title.trim() || !content.trim()}>
            {saving ? 'Saving…' : 'Save'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}