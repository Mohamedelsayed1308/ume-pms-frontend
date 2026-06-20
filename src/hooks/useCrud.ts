'use client';

import { useState, useCallback } from 'react';
import api from '@/lib/api';
import { showToast, getErrorMessage } from '@/lib/toast';

export interface UseCrudOptions {
  baseUrl: string;
  onSuccess?: () => void;
  onError?: (error: string) => void;
}

export interface CrudState<T> {
  items: T[];
  loading: boolean;
  error: string | null;
  total: number;
  page: number;
  limit: number;
}

export function useCrud<T extends { id: string }>(options: UseCrudOptions) {
  const [state, setState] = useState<CrudState<T>>({
    items: [],
    loading: false,
    error: null,
    total: 0,
    page: 1,
    limit: 10,
  });

  const [saving, setSaving] = useState(false);

  // Fetch all items
  const fetchItems = useCallback(
    async (page = 1, limit = 10, params = {}) => {
      setState((prev) => ({ ...prev, loading: true, error: null }));
      try {
        const response = await api.get(options.baseUrl, {
          params: { page, limit, ...params },
        });
        const data = response.data.data || response.data;
        const total = response.data.total || data.length;
        setState((prev) => ({
          ...prev,
          items: Array.isArray(data) ? data : [],
          total,
          page,
          limit,
          loading: false,
        }));
      } catch (error) {
        const message = getErrorMessage(error);
        setState((prev) => ({ ...prev, error: message, loading: false }));
        options.onError?.(message);
      }
    },
    [options]
  );

  // Fetch single item
  const fetchItem = useCallback(
    async (id: string) => {
      try {
        const response = await api.get(`${options.baseUrl}/${id}`);
        return response.data;
      } catch (error) {
        const message = getErrorMessage(error);
        showToast.error(message);
        throw error;
      }
    },
    [options.baseUrl]
  );

  // Create item
  const createItem = useCallback(
    async (data: Partial<T>) => {
      setSaving(true);
      try {
        const response = await api.post(options.baseUrl, data);
        showToast.success('Created successfully');
        options.onSuccess?.();
        return response.data;
      } catch (error) {
        const message = getErrorMessage(error);
        showToast.error(message);
        options.onError?.(message);
        throw error;
      } finally {
        setSaving(false);
      }
    },
    [options]
  );

  // Update item
  const updateItem = useCallback(
    async (id: string, data: Partial<T>) => {
      setSaving(true);
      try {
        const response = await api.put(`${options.baseUrl}/${id}`, data);
        showToast.success('Updated successfully');
        options.onSuccess?.();
        return response.data;
      } catch (error) {
        const message = getErrorMessage(error);
        showToast.error(message);
        options.onError?.(message);
        throw error;
      } finally {
        setSaving(false);
      }
    },
    [options]
  );

  // Delete item
  const deleteItem = useCallback(
    async (id: string) => {
      setSaving(true);
      try {
        await api.delete(`${options.baseUrl}/${id}`);
        showToast.success('Deleted successfully');
        options.onSuccess?.();
      } catch (error) {
        const message = getErrorMessage(error);
        showToast.error(message);
        options.onError?.(message);
        throw error;
      } finally {
        setSaving(false);
      }
    },
    [options]
  );

  return {
    state,
    saving,
    fetchItems,
    fetchItem,
    createItem,
    updateItem,
    deleteItem,
    setState,
  };
}
